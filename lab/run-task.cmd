@echo off
rem run-task.cmd <marker> <script-relative-to-kit> [args...]
rem Runs a kit script from the share as the signed-in user and writes <marker>.exit holding its exit code.
set MARK=%1
set SCRIPT=%2
shift
shift
cmdkey /add:192.168.5.217 /user:mig /pass:Lab-mig-share-2026 >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \\192.168.5.217\pcmig\kit\%SCRIPT% %1 %2 %3 %4 %5 %6
echo %ERRORLEVEL% > \\192.168.5.217\pcmig\logs\%MARK%.exit
