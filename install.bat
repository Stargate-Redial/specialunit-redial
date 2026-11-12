@echo off
rem Stargate Redial: runs install.ps1 with Windows PowerShell.
rem Double-click it, or pass options, e.g.:  install.bat -UT2004Dir "D:\Games\UT2004"  -ZipPath "D:\SpecialUnit.zip"
setlocal
title Special Unit: Redial - installation
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set RC=%ERRORLEVEL%
if not "%RC%"=="0" echo. & echo Installation FAILED (exit code %RC%).
if "%~1"=="" pause
exit /b %RC%
