@echo off
REM Build WC3 CrashProtector as version.dll (64-bit, for WC3 Reforged).
REM Run build.bat to compile and sign without installing.
REM Run build.bat "D:\Program Files (x86)\Warcraft III\_retail_\x86_64" to also install.
REM CrashProtector forwards normal version APIs to the Windows system DLL.
REM Close WC3 before installing and copy the matching symbols.txt separately.
setlocal
cd /d "%~dp0"
rem Resolve PowerShell before compiling. An explicit override must name an existing executable.
if defined CRASHPROTECTOR_PWSH goto check_pwsh
for %%I in (pwsh.exe) do set "CRASHPROTECTOR_PWSH=%%~$PATH:I"
if defined CRASHPROTECTOR_PWSH goto check_pwsh
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "CRASHPROTECTOR_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined CRASHPROTECTOR_PWSH goto check_pwsh
if exist "%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe" set "CRASHPROTECTOR_PWSH=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe"
:check_pwsh
if not defined CRASHPROTECTOR_PWSH (
    echo ERROR: PowerShell 7 was not found. Install it or set CRASHPROTECTOR_PWSH to the full path of pwsh.exe.
    exit /b 1
)
if not exist "%CRASHPROTECTOR_PWSH%" (
    echo ERROR: CRASHPROTECTOR_PWSH does not point to an existing executable.
    exit /b 1
)
"%CRASHPROTECTOR_PWSH%" -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -lt 7) { exit 1 }"
if errorlevel 1 (
    echo ERROR: Signing requires a working PowerShell 7 executable.
    exit /b 1
)
REM Activate the x64 compiler environment; adjust this path for another machine.
call "D:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Could not activate x64 build environment.
    exit /b 1
)

echo Building CrashProtector (x64)...
REM Keep unsigned compiler output separate from the signed release DLL.
if not exist build mkdir build
if not exist build (
    echo ERROR: Could not create the build directory.
    exit /b 1
)
pushd build
if errorlevel 1 exit /b 1
cl /nologo /O2 /W3 /LD /Fe:version.dll ..\crash_protector.c ..\hde64.c /link /DEF:..\version.def /MACHINE:X64 user32.lib
set "BUILD_RESULT=%ERRORLEVEL%"
popd
if not "%BUILD_RESULT%"=="0" (
    echo === Build FAILED ===
    exit /b %BUILD_RESULT%
)

echo Signing CrashProtector...
"%CRASHPROTECTOR_PWSH%" -NoProfile -File "%~dp0sign-local.ps1"
if errorlevel 1 (
    echo === Signing or output replacement FAILED ===
    echo See the signing error above. Do not install the unsigned build\version.dll.
    exit /b 1
)
if not exist "version.dll" (
    echo ERROR: Signed version.dll not found after signing.
    exit /b 1
)
echo.
echo === Build and signing successful! ===
echo Output: %~dp0version.dll

if "%~1"=="" (
    echo.
    echo To also install: build.bat "path\to\Warcraft III\_retail_\x86_64"
    exit /b 0
)
set "WC3DIR=%~f1"
if /I "%WC3DIR%\"=="%~dp0" (
    echo ERROR: Installation directory must differ from the source directory.
    exit /b 1
)
if not exist "%WC3DIR%\Warcraft III.exe" (
    echo ERROR: Expected the Warcraft III x86_64 directory containing Warcraft III.exe.
    exit /b 1
)
echo.
echo Installing CrashProtector to: %WC3DIR%
echo Removing old version.dll from WC3 directory...
if exist "%WC3DIR%\version.dll" (
    del /F "%WC3DIR%\version.dll" >nul 2>&1
    if exist "%WC3DIR%\version.dll" (
        echo ERROR: Could not remove old version.dll. Close WC3 and any tools using the DLL, and check directory permissions.
        goto install_failed
    )
)

echo Copying signed CrashProtector version.dll...
copy /Y "version.dll" "%WC3DIR%\version.dll" >nul
if errorlevel 1 (
    echo ERROR: Copy failed. Close WC3 and any tools using the DLL, and check directory permissions.
    goto install_failed
)
REM Verify that the copy landed and contains the exact signed build.
if not exist "%WC3DIR%\version.dll" (
    echo ERROR: version.dll not found in WC3 directory after copy.
    goto install_failed
)
fc /b "version.dll" "%WC3DIR%\version.dll" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Installed version.dll does not match the signed build.
    goto install_failed
)
echo       Done. Installed DLL verified.
echo.
echo Copy matching symbols.txt beside Warcraft III.exe before launching.
echo Launch WC3 normally through Battle.net.
echo Logs are in your Windows Documents folder under CrashProtector\crash_protector.log.
echo To UNINSTALL: close WC3 and restore your backed-up files, or remove the added files.
echo === Installation complete! ===
exit /b 0

:install_failed
echo The signed local version.dll is ready for manual copying after resolving the error:
echo   copy /Y "%~dp0version.dll" "%WC3DIR%\version.dll"
exit /b 1
