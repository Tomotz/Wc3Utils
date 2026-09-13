# Requires PowerShell 7. Creates a local compatibility signature, without installing certificates.
[CmdletBinding()]
param(
    [string]$InputDll=(Join-Path $PSScriptRoot 'build\version.dll'),
    [string]$OutputDll=(Join-Path $PSScriptRoot 'version.dll'),
    [string]$SignToolPath='D:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe',
    [ValidateRange(1,3650)][int]$ValidityDays=3650
)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7) {throw 'Run this script with PowerShell 7 (pwsh).'}
$source=(Resolve-Path -LiteralPath $InputDll).Path
$destination=[IO.Path]::GetFullPath($OutputDll)
if([string]::Equals($source,$destination,[StringComparison]::OrdinalIgnoreCase)) {throw 'Choose a separate output file so the original DLL is preserved.'}
if(-not (Test-Path -LiteralPath $SignToolPath -PathType Leaf)) {throw 'Set -SignToolPath to the Windows SDK signtool.exe path.'}
$outputDirectory=Split-Path -Parent $destination
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$stagedDll=Join-Path $outputDirectory ('version.signed-'+[Guid]::NewGuid().ToString()+'.dll')
$keepStagedDll=$false
$pfxPath=Join-Path $env:TEMP ('CrashProtector-local-sign-'+[Guid]::NewGuid().ToString()+'.pfx')
$rsa=[System.Security.Cryptography.RSA]::Create(2048)
$certificate=$null
try {
    Copy-Item -LiteralPath $source -Destination $stagedDll
    $request=[System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=CrashProtector Local Build',$rsa,[System.Security.Cryptography.HashAlgorithmName]::SHA256,[System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
    $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,$true))
    $usage=[System.Security.Cryptography.OidCollection]::new()
    $null=$usage.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
    $request.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usage,$true))
    $certificate=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5),[DateTimeOffset]::UtcNow.AddDays($ValidityDays))
    [IO.File]::WriteAllBytes($pfxPath,$certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx,''))
    & $SignToolPath sign /fd SHA256 /f $pfxPath $stagedDll
    if($LASTEXITCODE -ne 0) {throw 'SignTool failed.'}
    $signature=Get-AuthenticodeSignature -LiteralPath $stagedDll
    if(-not $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) {throw 'The output does not contain the expected signature.'}
    # Sign and verify a separate file before replacing the release DLL. Replacing
    # the directory entry also avoids truncating a file with an open mapped view.
    try {
        if(Test-Path -LiteralPath $destination) {
            [IO.File]::Replace($stagedDll,$destination,[NullString]::Value)
        } else {
            [IO.File]::Move($stagedDll,$destination)
        }
    } catch {
        $keepStagedDll=$true
        throw "Signed DLL is ready at '$stagedDll', but could not replace '$destination'. Close programs inspecting or loading that DLL and retry. Details: $($_.Exception.Message)"
    }
    [IO.File]::WriteAllBytes((Join-Path $outputDirectory 'local-signing.cer'),$certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    [ordered]@{
        inputPath=$source;inputHash=(Get-FileHash -LiteralPath $source).Hash
        outputPath=$destination;outputHash=(Get-FileHash -LiteralPath $destination).Hash
        subject=$certificate.Subject;thumbprint=$certificate.Thumbprint
        expires=$certificate.NotAfter.ToString('o');windowsSignatureStatus=$signature.Status.ToString()
        windowsSignatureStatusMessage=$signature.StatusMessage;trustedStoresModified=$false
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputDirectory 'signature.json')
    Write-Output ('Signed copy: '+$destination)
} finally {
    if(-not $keepStagedDll -and (Test-Path -LiteralPath $stagedDll)) {Remove-Item -LiteralPath $stagedDll}
    if(Test-Path -LiteralPath $pfxPath) {Remove-Item -LiteralPath $pfxPath}
    if($certificate) {$certificate.Dispose()}
    $rsa.Dispose()
}

