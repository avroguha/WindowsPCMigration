@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Import-Profile.ps1" %*
echo.
pause
