## Libraries and utilities for WC3 map developers

This library contains all the utilities I created for developing wc3 maps that are in a mature enough state to share with others.
It also contains all the depandencies needed by my libraries, and some tests.

### CrashProtector -
Windows x64 DLL proxy that attempts recovery from unhandled WC3 crashes and records crash and hang diagnostics. The current signed distribution targets Reforged 3.0.0.24268 and includes matching partial symbols. See [installation and build instructions](CrashProtector/README.md) and [signing and sharing](CrashProtector/LOCAL-SIGNING.md).

### PdbPorter -
Tools for porting function and parameter symbols from an older executable with a matching PDB to a newer game build. See the [symbol-update workflow](CrashProtector/README.md#updating-symbols-after-a-wc3-patch) used by CrashProtector.

### DebugDumps -
Debugging tool for investigating desyncs by logging stacktraces, recently executed functions, active timers, and context-switching function calls. Automatically dumps diagnostic information when a player leaves the game.
https://www.hiveworkshop.com/threads/debugdumps-desync-debugging.357626/

### StringEscape -
Character escaping/unescaping utility that replaces unsupported characters with unprintable ones. Designed to minimize string size bloat while handling special characters that WC3's file system cannot support. Has 0 overhead for textual strings, and very small overhead for any string. Used in SyncStream and FileIO libraries

### SyncStream -
An optimized version of Trokkin's SyncStream library that allows syncing a string between all players. At least two times more efficient on any data you want to send. Safely syncs arbitrary amounts of data across clients using timers to spread network packets over time, with both callback-based and blocking APIs.

### FileIO -
Optimized version of file reading and writing system for WC3. Provides Save and Load functions with character escaping support, allowing any arbitrary data to be written and loaded back.

### Interpreter -
CLI tool that connects to your running WC3 game via terminal, enabling you to execute Lua code dynamically during gameplay or replay. Allows live debugging and function reimplementation without restarting the game.
https://www.hiveworkshop.com/threads/wc3interpreter.366724/

### LogUtils -
Logging system with memory-buffered writes, automatic file rotation, and replay-specific logging modes. Provides print-like interface (LogWrite) for debugging with minimal performance impact.
https://www.hiveworkshop.com/threads/logutils.357625/

### MiscUtils -
Collection of small utility functions including an improved ExecuteFunc hook (coroutine-based with argument support), game status detection (online/offline/replay), elapsed game time tracking (GetElapsedGameTime) and HandleChatCmd which parses chat commands starting with `-`