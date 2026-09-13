$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$testDirectory=Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('CrashProtector-symbol-tests-'+[Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $testDirectory | Out-Null
try {
    $batch=@"
@echo off
call "D:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d "$testDirectory"
cl /nologo /O2 /W3 /Fe:test.exe "$PSScriptRoot\symbol_resolution_test.c" "$project\hde64.c" /link user32.lib
if errorlevel 1 exit /b 1
test.exe
if errorlevel 1 exit /b 1
cl /nologo /O2 /W3 /Fe:capture_test.exe "$PSScriptRoot\code_capture_test.c" "$project\hde64.c" /link user32.lib
if errorlevel 1 exit /b 1
capture_test.exe
"@
    $batchPath=Join-Path $testDirectory 'build.cmd'
    Set-Content -LiteralPath $batchPath -Value $batch
    & $batchPath
    if($LASTEXITCODE -ne 0) {throw 'Symbol regression test failed.'}
} finally {
    $resolved=(Resolve-Path -LiteralPath $testDirectory).Path
    $tempRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'CrashProtector-symbol-tests-*') {throw 'Unexpected test cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
