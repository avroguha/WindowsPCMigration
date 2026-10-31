@echo off
start "" powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Migration-UI.ps1"
