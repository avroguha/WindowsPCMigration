@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-Profile.ps1" %*
echo.
pause
