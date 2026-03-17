# WC3 CrashProtector

A DLL proxy that prevents Warcraft III Reforged from crashing due to invalid pointer access violations.

## What It Does

CrashProtector intercepts access violation exceptions (invalid read/writes) and safely handles them by:
- Detecting when the game tries to read/write to invalid memory addresses
- For reads: returning 0 to the destination register
- For writes: discarding the write operation
- Advancing past the faulting instruction to continue execution
- Logging all caught crashes to `crash_protector.log`
- Showing notification balloons (windows notifications) on the 2nd and 50th saved crash
- Note - this is a very hacky mitigation for crashes, and the fix might not work in many cases as the program is left in a bad state, but it is tested and prevents real crashes.

This allows WC3 to continue running instead of crashing when it encounters invalid pointer bugs.

## How It Works

CrashProtector uses a technique called **DLL proxying**:

1. The game loads `version.dll` (a standard Windows DLL that WC3 uses)
2. Our custom `version.dll` is loaded instead of the system one
3. Our DLL installs a Vectored Exception Handler to catch crashes
4. All normal version.dll function calls are forwarded to the real system DLL (loaded from `C:\Windows\System32\version.dll` at runtime)
5. When a crash occurs, our handler catches it, fixes it, and lets the game continue

### Technical Details

- **Platform**: Windows x64 only (WC3 Reforged or any other game that is using version.dll)
- **Injection Method**: DLL proxying via version.dll
- **Exception Handling**: Vectored Exception Handler with priority 1 (first handler)
- **Instruction Skipping**: Uses HDE64 (Hacker Disassembler Engine) to decode and skip faulting instructions
- **Logging**: Lock-free async ring buffer with background writer thread
- **Stack Traces**: If the game executable has debug symbols (PDB), stack traces with function names and source lines are included in the log. DbgHelp is loaded dynamically — zero overhead when no symbols are present.

## Installation

### Option 1: Use Pre-built DLL (Quick)

1. Copy the pre-built `version.dll` to your WC3 Reforged x86_64 folder
   - Default location: `C:\Program Files (x86)\Warcraft III\_retail_\x86_64\version.dll`
   - Can probably work for WC3 classic as well - I think it should be in the root dir or under cef (`\Path\to\Warcraft III\version.dll`) 
2. Launch WC3 normally through Battle.net
3. Done! Crashes will be logged to `crash_protector.log` in the same folder

### Option 2: Build and Install (Not Recommended)
**Steps:**

1. Open PowerShell
2. Navigate to this folder
3. Run the build script with your WC3 path:
   ```
   build.bat "C:\Program Files (x86)\Warcraft III\_retail_\x86_64"
   ```
   (Adjust the path to match your WC3 installation)

This will:
1. Compile the CrashProtector DLL
2. Copy `version.dll` to your WC3 folder

## Usage

Just launch WC3 normally through Battle.net. The crash protector runs automatically.

When crashes are caught:
- A notification balloon appears on the 2nd and 50th crash
- All crashes are logged to `crash_protector.log` with timestamps, faulting module name + offset, a full register dump, and stack traces (when symbols are available)
- The game continues running

## Uninstallation

Delete `version.dll` from your WC3 x86_64 folder. WC3 will revert to using the system version.dll.

## Log File Example

```
[14:23:45.123] === CrashProtector loaded (PID 12345, symbols=YES) ===
[14:23:45.125] Vectored exception handler installed successfully
[14:23:45.126] Ready - monitoring for null pointer access violations
[14:24:12.456] SAVED #1: READ addr=0x0000000000000000 RIP=0x00007FF712345678 instrLen=7
[14:24:12.456]   Module: C:\Program Files (x86)\Warcraft III\_retail_\x86_64\Warcraft III.exe +0x12345678
[14:24:12.456]   RAX=0000000000000000 RBX=00000000DEADBEEF RCX=0000000000000001 RDX=0000000000000000
[14:24:12.456]   RSI=00000000004A2F10 RDI=0000000000000000 RBP=00000000006FF800 RSP=00000000006FF7A0
[14:24:12.456]   R8 =0000000000000000 R9 =0000000000000000 R10=0000000000000000 R11=0000000000000246
[14:24:12.456]   R12=0000000000000000 R13=0000000000000000 R14=0000000000000000 R15=0000000000000000
[14:24:12.456]   --- Stack Trace ---
[14:24:12.456]   [ 0] 0x00007FF712345678  SomeFunction+0x1A  (game.cpp:1234)
[14:24:12.456]   [ 1] 0x00007FF71234ABCD  CallerFunction+0x42
[14:24:12.456]   [ 2] 0x00007FF712340000  main+0x100  (main.cpp:56)
[14:24:15.789] SAVED #2: WRITE addr=0x0000000000000010 RIP=0x00007FF712345ABC instrLen=6
[14:24:15.789]   Module: C:\Program Files (x86)\Warcraft III\_retail_\x86_64\Warcraft III.exe +0x345ABC
[14:24:15.789]   ...
```

## Building from Source

### File Structure
- `crash_protector.c` - Main crash handler and version.dll proxy implementation
- `hde64.c` / `hde64.h` - Instruction length decoder for x64
- `version.def` - Export definitions for version.dll functions
- `build.bat` - Automated build and installation script

### Manual Build

If you need to build manually without installation:

```batch
call "C:\Program Files (x86)\Microsoft Visual Studio\XX\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
cl /O2 /W3 /LD /Fe:version.dll crash_protector.c hde64.c /link /DEF:version.def /MACHINE:X64 user32.lib
```

This produces `version.dll` which you can manually copy to your WC3 folder.

## Notes

- Only works with WC3 Reforged (64-bit)
- Currently catches all access violations, not just null pointer (address check at line 126 is commented out)
- Uses instruction skipping, so some game state may become inconsistent if crashes occur in critical code paths
- Performance impact is minimal - handler only activates on exceptions
