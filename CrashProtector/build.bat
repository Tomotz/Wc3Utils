@echo off
REM Build WC3 CrashProtector as version.dll (64-bit, for WC3 Reforged)
REM
REM HOW TO USE:
REM   1. Open a regular Command Prompt (cmd) or VSCode terminal
REM   2. cd to this folder
REM   3. Run: build.bat
REM
REM Usage: from power shell: ./build.bat "D:\Program Files (x86)\Warcraft III\_retail_\x86_64" "(adjust path to your wc install location)"

REM After this we install CrashProtector into WC3 Reforged directory
REM
REM This copies our version.dll (CrashProtector) into the game folder.
REM
REM When WC3 starts, it loads our version.dll first. Our DLL installs the
REM crash handler, and forwards all normal version.dll calls to the system version.dll.


REM Activate the x64 compiler environment - Change this to wherever you have Visual Studio Build Tools installed
call "D:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Could not activate x64 build environment
    exit /b 1
)

echo Building CrashProtector (x64)...

REM --- Compile ---
cl /O2 /W3 /LD /Fe:version.dll crash_protector.c hde64.c /link /DEF:version.def /MACHINE:X64 user32.lib

if %ERRORLEVEL% EQU 0 (
    echo.
    echo === Build successful! ===
    echo Output: version.dll
) else (
    echo.
    echo === Build FAILED ===
    exit /b 1
)


if "%~1"=="" (
    echo.
    echo Usage: install.bat "D:\Program Files (x86)\Warcraft III\_retail_\x86_64" "(adjust path to your wc install location)"
    echo.
    exit /b 1
)

set WC3DIR=%~1

if not exist "version.dll" (
    echo ERROR: version.dll not found in current directory.
    echo Run build.bat first!
    exit /b 1
)

echo.
echo Installing CrashProtector to: %WC3DIR%
echo.

REM Copy our proxy version.dll
echo Copying CrashProtector version.dll...
copy /Y "version.dll" "%WC3DIR%\version.dll" >nul
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Could not copy. Make sure WC3 is not running. Try running as Administrator.
    exit /b 1
)
echo       Done.

echo.
echo === Installation complete! ===
echo.
echo Launch WC3 normally through Battle.net.
echo If a crash is caught, you'll see a popup and a log file:
echo   %WC3DIR%\crash_protector.log
echo.
echo To UNINSTALL: delete version.dll from the WC3 folder.

