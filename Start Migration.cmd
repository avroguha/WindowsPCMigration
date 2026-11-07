@echo off
rem Starts PC Migration. The exe needs nothing installed (it uses the .NET Framework built into Windows) and no admin rights.
rem If the company blocks unsigned programs, use Export.cmd on the old PC and Compare-Software.cmd + Import.cmd on the new one.
start "" "%~dp0PCMigration.exe"
