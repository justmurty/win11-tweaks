@echo off
REM ===================================================================
REM  win11-tweaks launcher
REM  - Self-elevates (UAC), then runs Invoke-Win11Tweaks.ps1 in a
REM    visible window so you can watch the progress live.
REM  - Keeps the window open at the end (press a key to close).
REM  - The log file is written next to the script: win11-tweaks_*.log
REM
REM  Usage:
REM    Double-click            -> real run (applies tweaks + installs apps)
REM    Run-Win11Tweaks.bat -DryRun  -> preview only, changes nothing
REM ===================================================================
setlocal
set "HERE=%~dp0"
set "PS1=%HERE%Invoke-Win11Tweaks.ps1"

REM --- Self-elevate to Administrator if needed ---
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges [UAC prompt]...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    ) else (
        powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'"
    )
    exit /b
)

cd /d "%HERE%"
if not exist "%PS1%" (
    echo ERROR: cannot find "%PS1%"
    echo Put Run-Win11Tweaks.bat in the same folder as Invoke-Win11Tweaks.ps1
    pause
    exit /b 1
)

echo ============================================================
echo   win11-tweaks   ^(running as Administrator^)
echo   Script : %PS1%
echo   Args   : %*
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%errorlevel%"

echo.
echo ============================================================
echo   Finished ^(exit %RC%^).
echo   Log file is next to the script:  %HERE%win11-tweaks_*.log
echo ============================================================
echo.
pause
