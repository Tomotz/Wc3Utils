# Signing and sharing CrashProtector

## Current distribution

The current release targets **Warcraft III Reforged 3.0.0.24268 (Windows x64)** and contains a self-signed `version.dll` with matching partial `symbols.txt`. See the [main README](README.md) for installation, recovery limitations, logs, and symbol generation.

The DLL's public certificate is embedded in its signature. It is not tied to the build machine or Windows account, and recipients do not need the private key. No separate certificate installation was needed in local testing. This is not a publicly trusted publisher signature: Windows can report an untrusted root, including an `UnknownError` status with that explanation. Other PCs and future WC3 acceptance policies have not been verified.

The current distributed certificate expires **September 10, 2036**. The DLL has **no trusted timestamp**. Re-sign and redistribute before expiry; acceptance may change earlier after a game update. A trusted timestamp can preserve signature validity after certificate expiry under applicable verification rules, but does not make a self-signed certificate publicly trusted. See [Microsoft's Authenticode timestamp documentation](https://learn.microsoft.com/windows/win32/seccrypto/time-stamping-authenticode-signatures).

## Build and signing outputs

From `CrashProtector`, run `.\build.bat`. It compiles into `build/`, then runs `sign-local.ps1` using PowerShell 7. The build discovers it via `CRASHPROTECTOR_PWSH`, PATH, the standard installation directory, or the local Codex runtime; a missing or invalid executable stops the build before compilation. An optional game `x86_64` directory argument installs the signed DLL; it does not copy symbols or recreate a release ZIP. Close WC3 before installing. MSVC and Windows SDK paths are currently specific to the local development machine; see [build prerequisites](README.md#build-and-install-from-source).

| Path | Purpose |
| --- | --- |
| `build/version.dll` | Unsigned compiler output; do not distribute this file. |
| `version.dll` | Signed output to install and distribute. |
| `local-signing.cer` | Public certificate export; not required in the release ZIP. |
| `signature.json` | Build hashes, signer thumbprint, expiry, and Windows signature status. |

To sign separately after a successful compilation:

```powershell
pwsh -NoProfile -File .\sign-local.ps1
```

Signing first prepares and verifies a uniquely named `version.signed-*.dll` beside the output, then replaces `version.dll`. This avoids overwriting a mapped DLL in place. If another process blocks replacement, the script fails with a clear message and retains the signed file at the reported path; close the program using the output and retry. Temporary signing files are removed after success or signing failure.

The defaults are input `build/version.dll` and output `version.dll`. `-SignToolPath` overrides the SDK executable path. Each signing run generates a new RSA code-signing certificate with a default lifetime of 3,650 days, embeds its public certificate, and deletes the temporary private-key PFX in a cleanup block. No Windows trust stores are modified. The script does not request a timestamp. Rebuilding or editing the DLL requires a new signature; expiry for each new signing run is recorded in `signature.json`.

## Create or refresh a release

Build and sign first, then confirm that `symbols.txt` targets the intended game build. Update the target build, certificate expiry, and behavior in [RELEASE-README.txt](RELEASE-README.txt) when needed. From `CrashProtector`, the following packages the current build:

```powershell
$releaseName = 'CrashProtector-wc3-3.0.0.24268-20260913'
$releaseDirectory = Join-Path .\releases $releaseName
New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
Copy-Item -LiteralPath .\version.dll -Destination (Join-Path $releaseDirectory 'version.dll')
Copy-Item -LiteralPath .\symbols.txt -Destination (Join-Path $releaseDirectory 'symbols.txt')
Copy-Item -LiteralPath .\RELEASE-README.txt -Destination (Join-Path $releaseDirectory 'README.txt')
$checksums = foreach ($name in @('version.dll', 'symbols.txt', 'README.txt')) {
    (Get-FileHash -LiteralPath (Join-Path $releaseDirectory $name) -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $name
}
$checksums | Set-Content -LiteralPath (Join-Path $releaseDirectory 'SHA256SUMS.txt')
$releaseFiles = @('version.dll', 'symbols.txt', 'README.txt', 'SHA256SUMS.txt') |
    ForEach-Object { Join-Path $releaseDirectory $_ }
Compress-Archive -LiteralPath $releaseFiles -DestinationPath (Join-Path .\releases ($releaseName + '.zip')) -Force
```

Change the release name for a different target build or release date. Verify that the ZIP contains exactly those four files and that its checksums match. Share the ZIP, without local logs, executable dumps, rollback files, public-certificate sidecars, or private-key material. Recipients close WC3, back up existing files, and copy the DLL and text symbols beside `Warcraft III.exe`.

## Symbol behavior

The current table has PE timestamp `6AA4DE70`, 54,250 functions, and 125,213 parameter records. Real named debug symbols take precedence; matching text names override export-only names and synthetic ordinals, including those returned by DbgHelp with `Flags=0`. Named exports remain a fallback. Ordinal placeholders are never printed as function names: unresolved names display as `???`, with addresses retained. Unknown parameter values display as `?`.

The table is a partial port, so unresolved frames and imperfect matches remain possible. The resolver uses a 32-bit parameter index and only applies the text table to addresses inside the main executable.

## Validation and local rollback

Self-signed builds passed local startup checks and the user subsequently confirmed gameplay compatibility and improved symbol names. The earlier build's 60-second startup check is recorded as such; it is not a startup test of every subsequent artifact. The ordinal-suppression update passed the compiled regression tests and its installed DLL hash was verified. No crash was deliberately induced for these checks.

Run the current regression from `CrashProtector` with:

```powershell
pwsh -NoProfile -File .\tests\run.ps1
```

The tests cover symbol precedence, unflagged ordinals, ordinal suppression, named exports, large parameter indices, and cross-module address isolation.

Local rollback backups are retained under ignored `local-state/`:

- `initial-install/`: Microsoft baseline, original installation metadata, and `restore-baseline.ps1`.
- `symbol-fix/`: original working signed DLL, current installation metadata, and `restore-previous.ps1`.

To restore the original working signed CrashProtector, close WC3 and run `local-state/symbol-fix/restore-previous.ps1`. To then restore the Microsoft baseline and disable CrashProtector, run `local-state/initial-install/restore-baseline.ps1`. These local scripts verify expected hashes before overwriting files and are not portable installers for recipients.

The obsolete `diagnostics/` directory has been removed. `build/`, `releases/`, and `local-state/` are ignored local output; rollback files are intentionally retained. Older release archives kept in the working tree are historical and should not be confused with the current ZIP.

## Runtime capture update

Code capture is disabled in the current source and signed distribution build by commenting out `InitCodeCapture();`. Startup, first-crash, and manual snapshots are available in diagnostic builds after uncommenting that call and rebuilding/signing. See the [capture and symbol workflow](README.md#updating-symbols-after-a-wc3-patch). When capture is enabled, its buffer remains allocated for the game session (about 50 MiB for this build). `local-state/runtime-capture/` preserves the preceding DLL and symbol table, plus installation metadata. Temporary snapshots, test logs, intermediate builds, and analysis outputs have been removed. The symbol-fix rollback script continues to validate the current installed hash before restoring its original working DLL. The user's subsequent first-crash capture recovered the missing pathfinding functions and produced the current 54,250-function table. Coverage remains partial.
