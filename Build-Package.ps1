# Builds dist\PCMigration-kit.zip - the files a person needs to run the migration (nothing from lab\ or sample-output\).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$files = @(
    'Start Migration.cmd',      # double-click this: the wizard
    'Migration-UI.ps1',         # the wizard
    'MigrationCommon.psm1',     # shared code
    'catalog.json',             # what counts as a setting
    'Export-Profile.ps1',       # engine: old PC
    'Compare-Software.ps1',     # engine: what to install
    'Import-Profile.ps1',       # engine: new PC
    'Export.cmd', 'Compare-Software.cmd', 'Import.cmd',   # command-line launchers (optional)
    'README.md', 'VERSION'
)
$stage = Join-Path $env:TEMP 'PCMigration-kit'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null
foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination $stage }
$dist = Join-Path $root 'dist'; New-Item -ItemType Directory -Force -Path $dist | Out-Null
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
Get-ChildItem $dist -Filter 'PCMigration-kit-*.zip' | Remove-Item -Force
$zip = Join-Path $dist "PCMigration-kit-$version.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item $stage -Recurse -Force
"$zip  ($([math]::Round((Get-Item $zip).Length / 1KB)) KB, $($files.Count) files)"
