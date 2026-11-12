@echo off
rem Stargate Redial: runs install.ps1 -Uninstall with Windows PowerShell (removes the SpecialUnit folder and the shortcuts).
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall %*
set RC=%ERRORLEVEL%
if not "%RC%"=="0" echo. & echo Uninstall FAILED (exit code %RC%).
if "%~1"=="" pause
exit /b %RC%
