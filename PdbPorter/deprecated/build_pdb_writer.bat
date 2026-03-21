@echo off
REM Build pdb_writer.exe — must be run from a Developer Command Prompt for VS
REM (or "x64 Native Tools Command Prompt for VS 2022")

cl.exe /nologo /O2 /W3 /Fe:pdb_writer.exe pdb_writer.cpp /link /MACHINE:X64
if %errorlevel% neq 0 (
    echo.
    echo Build failed. Make sure you're running from a Developer Command Prompt.
    exit /b 1
)
echo.
echo Built: pdb_writer.exe
