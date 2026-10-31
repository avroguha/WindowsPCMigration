@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Compare-Software.ps1" %*
echo.
pause
