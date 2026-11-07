# Runs INSIDE a lab VM (through run-on-vm.sh, which allows at most six arguments): drives the app from the share
# with ui-test.ps1 against the share's backup root, and leaves the PNG captures in \\share\logs\shots.
#   bash run-on-vm.sh 9311 user 'lab\vm-ui-test.ps1' -Mode export
param([ValidateSet('export', 'import')][string]$Mode = 'export', [string]$Theme = 'light')
$share = '\\192.168.5.217\pcmig'
$log = Join-Path "$share\logs" ("{0}-ui-{1}.log" -f $env:COMPUTERNAME, $Mode)
Start-Transcript -Path $log -Force | Out-Null
try {
    # a copy in the profile, so the exe runs from a local path (no network-zone prompts) exactly as a user would run it
    $local = Join-Path $env:LOCALAPPDATA 'PCMigration-test'; New-Item -ItemType Directory -Force -Path $local | Out-Null
    Copy-Item -LiteralPath "$share\kit\PCMigration.exe" -Destination "$local\PCMigration.exe" -Force
    "exe: $local\PCMigration.exe ($((Get-Item "$local\PCMigration.exe").Length) bytes, version $((Get-Item "$local\PCMigration.exe").VersionInfo.FileVersion))"
    "dotnet SDK present: $([bool](Get-Command dotnet -ErrorAction SilentlyContinue))   .NET Framework release: $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release)"
    "admin: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))   session: $([System.Diagnostics.Process]::GetCurrentProcess().SessionId)"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\ui-test.ps1" -Mode $Mode -ShotDir "$share\logs\shots" -MigRoot "$share\PCMigration" -Exe "$local\PCMigration.exe" -Theme $Theme 2>&1 | ForEach-Object { "$_" }
    "ui-test exit code: $LASTEXITCODE"
    $appLog = Join-Path $env:LOCALAPPDATA 'PCMigration\logs\app.log'
    if (Test-Path $appLog) { '--- app.log (tail)'; Get-Content $appLog -Tail 15 }
} finally { Stop-Transcript | Out-Null }
