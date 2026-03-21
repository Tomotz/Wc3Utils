# WC3 CrashProtector

A DLL proxy that prevents Warcraft III Reforged from crashing due to invalid pointer access violations, and detects hangs.

## What It Does

There are a few main reasons that players drop undesireably from games:
 - Network disconnects - there was no connectivy between host and client and game drops the player. This used to be mitigate in classic by the 45 seconds grace period before a player is kicked, but no longer. I think these looks like the player just exits to scoreboard window.
 - Desync - there is a difference between players in how they see the game state (some unit exist for one player and not the other). Game notices and desyncs one of the players to avoid inconncistancy. If a desync happened, you will see a desync log under \Documents\Warcraft III\Errors
 - Crashes - error in the application caused the game to crash and close. When these happen you will see a Crash log under \Documents\Warcraft III\Errors that will also state the reason for the crash.
 - Freezes - A very heavy compute is causing the application to hang. Can be an infinite loop, or just a very very long one that is intensive enough to make the process. When this happens the game window will freeze, and windows will offer to restart it.

 In this project we try to avoid crashes and make crashes and freezes more informative (allowing you to classify them, and possibly even understand what caused them).
 This project only handles access violation crashes (which are the most common crash in the games I played). It will not solve or log any other type of crash.

**Crash protection** — intercepts unhandled access violation exceptions and safely recovers:
- Detecting when the game tries to read/write/execute invalid memory addresses
- For reads: returning 0 to the destination register
- For writes: discarding the write operation (nop)
- For execute (DEP): simulating a return to the caller
- Advancing past the faulting instruction to continue execution

**Hang detection** — a watchdog thread monitors the game's main thread and logs diagnostics (all thread stacks) when it stops responding.

**Logging** — all crashes and hangs are logged to `Documents\CrashProtector\crash_protector.log` with register dumps, and module info. If symbols are available, will also generat stack traces and function args. Notification balloons appear on the 1st and 20th saved crash, and when a hang is detected to let the user know.

Only truly unhandled exceptions are caught — the game's own exception handlers (`__try/__except`) run first and are not interfered with.

Note: this is a very hacky mitigation for crashes. Skipping faulting instructions leaves the program in a potentially inconsistent state, and might lead to later errors, but it is tested and prevents real crashes in practice. It is not expected to cause any issue when no crashes were encountered.

## How It Works

CrashProtector uses **DLL proxying** combined with an **Unhandled Exception Filter (UEF)**:

1. On normal game startup, `version.dll` (a standard Windows DLL) is loaded.
2. We replace it with a custom `version.dll` that is saved in the game executable folder, and is loaded instead of it.
3. All normal version.dll function calls are forwarded to the real system DLL (loaded from `System32` at runtime).
4. A watchdog thread waits for the game to finish initializing (window created). This watchdog checks for hangs in the main thread periodically.
5. After init, a UEF is installed via `SetUnhandledExceptionFilter` — this only fires for exceptions that no SEH handler (try/catch block) caught
6. When a real crash occurs, the UEF recovers and lets the game continue

### Windows Exception Handling — How Exceptions Are Dispatched

Understanding why we use a UEF requires knowing the Windows exception dispatch order:

1. **Debugger** (first-chance notification)
2. **VEH** (Vectored Exception Handlers) — global, not frame-based. Run before SEH regardless of call stack position. Registered via `AddVectoredExceptionHandler`.
3. **SEH** (Structured Exception Handling) — frame-based `__try/__except` handlers. The system walks the stack searching for a handler. On x64, SEH is table-based: each function's `RUNTIME_FUNCTION` entry points to `UNWIND_INFO` which may have `UNW_FLAG_EHANDLER` indicating an exception handler.
4. **UEF** (Unhandled Exception Filter) — registered via `SetUnhandledExceptionFilter`. Only reached if no SEH handler caught the exception. The filter can return `EXCEPTION_CONTINUE_EXECUTION` to resume with a modified context.
5. **Debugger** (second-chance notification)
6. **Process termination** (`ExitProcess`)

Additionally, **VCH** (Vectored Continue Handlers, via `AddVectoredContinueHandler`) fire after any handler returns `EXCEPTION_CONTINUE_EXECUTION` — useful for observing which exceptions were handled, but not for catching unhandled ones.

### Additional Features

- **Hang detection**: A watchdog thread monitors the main thread's message loop via `SendMessageTimeout`. If the main thread stops responding, all thread stacks are dumped to the log.
- **Symbol support**: If a PDB is available for the game executable, stack traces include function names, parameters, and source file/line numbers. DbgHelp is loaded dynamically — zero overhead when no symbols are present.
- **Archive logs**: On the first crash or hang, an archive log with a timestamped filename is created alongside the main log.

### Technical Details

- **Platform**: Windows x64 only
- **Injection method**: DLL proxying via version.dll
- **Exception handling**: Unhandled Exception Filter (installed after game init)
- **Instruction decoding**: HDE64 (Hacker Disassembler Engine) to decode and skip faulting instructions
- **Logging**: Lock-free async ring buffer with background writer thread
- **Stack traces**: Via DbgHelp (StackWalk64, SymFromAddr, SymGetLineFromAddr64)

## Installation

### Option 1: Use Pre-built DLL

1. Copy the pre-built `version.dll` to your WC3 Reforged x86_64 folder
   - Default location: `C:\Program Files (x86)\Warcraft III\_retail_\x86_64\version.dll`
   - Can probably work for WC3 classic as well and maybe even for other games — Should always be next to the game executable file (not shortcut)
2. Launch WC3 normally through Battle.net (If game is already open you must restart it)
3. Crashes will be logged to `Documents\CrashProtector\crash_protector.log`

### Option 2: Build and Install

1. Open PowerShell
2. Navigate to this folder
3. Run the build script with your WC3 path (might not be C:\):
   ```
   .\build.bat "C:\Program Files (x86)\Warcraft III\_retail_\x86_64"
   ```

This will compile the DLL and copy `version.dll` to your WC3 folder.

## Usage

Launch WC3 normally through Battle.net. The crash protector runs automatically.

When crashes are caught:
- A notification balloon appears on the 1st and 20th crash
- All crashes are logged with timestamps, faulting module + offset, register dump, and stack traces+arguments (when symbols are available)
- The game continues running

## Uninstallation

Delete `version.dll` from your WC3 x86_64 folder. WC3 will revert to using the system version.dll.

## Log File

Logs are written to `Documents\CrashProtector\crash_protector.log` (overwritten each launch). When multiple crashes or a hang are detected, an archive log with a timestamp is also created.

```
[14:23:45.123] === CrashProtector loaded (PID 12345, symbols=YES) ===
[14:23:45.126] Ready - monitoring for invalid pointer access violations
[14:23:45.126] Watchdog thread started
[14:23:47.200] Watchdog: found game window (HWND=0x1234, tid=5678)
[14:23:47.200] Crash recovery filter installed
[14:24:12.456] ACCESS_VIOLATION #1: WRITE addr=0x00000023FFFFFFF3 RIP=0x00007FF780C8C1E1
[14:24:12.456]   Module: Warcraft III.exe +0x4DC1E1 (???) instrLen=3
[14:24:12.456]   RAX=... RBX=... RCX=... ...
[14:24:12.456]   --- Stack Trace (Newest first) ---
[14:24:12.456]   #0x0  0x00007FF780C8C1E1 in SomeFunction (param1=0x0, param2=0x1)
[14:24:12.456]   #0x1  0x00007FF780C80000 in CallerFunction () at game.cpp:1234
```

## Building from Source

### File Structure
- `crash_protector.c` — Main crash handler, watchdog, and version.dll proxy
- `hde64.c` / `hde64.h` — Instruction length decoder for x64
- `version.def` — Export definitions for version.dll proxy functions
- `build.bat` — Automated build and installation script

### Manual Build

```batch
call "C:\Program Files (x86)\Microsoft Visual Studio\XX\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
cl /O2 /W3 /LD /Fe:version.dll crash_protector.c hde64.c /link /DEF:version.def /MACHINE:X64 user32.lib
```

This produces `version.dll` which you can manually copy to your WC3 folder.

## Notes

- Only works with 64-bit Windows executables
- Performance impact is minimal — the filter only activates on unhandled exceptions
- The game's own exception handlers (SEH) are never interfered with