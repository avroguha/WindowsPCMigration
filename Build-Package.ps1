# Builds dist\PCMigration-kit-<version>.zip - the app plus the engine scripts as plain files, for a company that
# blocks unsigned exes but allows PowerShell (Export.cmd / Import.cmd then do the same work from the command line).
# Nothing from src\, lab\ or sample-output\ goes in. Run Build-Exe.ps1 first (it calls this script itself).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
$files = @(
    'Start Migration.cmd',      # double-click this: starts the app (PCMigration.exe)
    'MigrationCommon.psm1',     # shared code
    'catalog.json',             # what counts as a setting
    'Export-Profile.ps1',       # engine: old PC
    'Compare-Software.ps1',     # engine: what to install
    'Import-Profile.ps1',       # engine: new PC
    'UI-Probe.ps1',             # engine: read-only questions the app asks
    'Export.cmd', 'Compare-Software.cmd', 'Import.cmd',   # command-line launchers (optional)
    'README.md', 'VERSION'
)
$exe = Join-Path $root "dist\PCMigration-$version.exe"
if (-not (Test-Path -LiteralPath $exe)) { throw "Build the exe first: $exe is missing (run Build-Exe.ps1)" }
$stage = Join-Path $env:TEMP 'PCMigration-kit'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null
foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination $stage }
Copy-Item -LiteralPath $exe -Destination (Join-Path $stage 'PCMigration.exe')
$dist = Join-Path $root 'dist'; New-Item -ItemType Directory -Force -Path $dist | Out-Null
Get-ChildItem $dist -Filter 'PCMigration-kit-*.zip' | ForEach-Object { $f = $_; try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { Write-Warning "old build still open, left in place: $($f.Name)" } }   # an older exe may be running
$zip = Join-Path $dist "PCMigration-kit-$version.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item $stage -Recurse -Force
"$zip  ($([math]::Round((Get-Item $zip).Length / 1KB)) KB, $($files.Count + 1) files)"
