CrashProtector for Warcraft III Reforged 3.0.0.24268 (Windows x64)

INSTALL
1. Close Warcraft III.
2. Back up any existing version.dll and symbols.txt beside Warcraft III.exe.
3. Copy this package's version.dll and symbols.txt into Warcraft III\_retail_\x86_64.
4. Launch normally through Battle.net.

Keep the original Blizzard war3_loader.dll. Do not replace Windows system files.
To uninstall, close WC3 and restore your backups, or remove the two added files if neither existed before installation.

LOGS AND SYMBOLS
Logs are under your Windows Documents folder, in CrashProtector\crash_protector.log. The main log is overwritten each launch; an archive is created after the first reported crash or hang. Code capture is disabled in this release: it does not write executable snapshots or allocate their capture buffer. Crash recovery, crash/hang logging, and symbol resolution remain enabled.

The included partial symbol table targets build 24268 (PE timestamp 6AA4DE70), with 54,250 functions and 125,213 parameter records. A different game build needs matching symbols. Real function names and addresses are retained; synthetic Ordinal42, Ordinal1, and similar placeholders display as ??? when no real name is available. An argument value of ? means it could not be recovered.

SIGNATURE AND COMPATIBILITY
This DLL is self-signed, not signed by a publicly trusted publisher. No separate certificate installation was needed in local testing with build 24268, and the DLL is not tied to the build machine. Other PCs and future game updates remain unverified. Windows may report an untrusted signer.

This certificate expires September 10, 2036. The signature has no trusted timestamp; obtain a newly signed build before expiry. Future WC3 updates may change acceptance sooner.

Crash recovery is a mitigation and cannot guarantee that the game continues or that game state remains correct after a fault. Hang diagnostics do not repair hangs. CrashProtector does not fix network disconnects or desyncs.

PACKAGE
version.dll: signed CrashProtector DLL.
symbols.txt: partial function/parameter table for this game build.
README.txt: these instructions.
SHA256SUMS.txt: checksums for the other three files.
