# Builds dist\PCMigration-<version>.exe - the single-file PC Migration app.
#
# The app is a C# / WPF program (src\PCMigration) that targets the .NET Framework 4.8 built into Windows 10 and 11,
# so the exe needs nothing installed on the computer it runs on and no admin rights. The engine (the PowerShell
# scripts + catalog.json) is embedded in the exe and unpacked to %LOCALAPPDATA%\PCMigration\kit-<version> at start.
#
# Building needs the .NET SDK on THIS machine only. It is installed per user (no admin) by this script if missing:
#   $env:LOCALAPPDATA\Microsoft\dotnet   (dotnet-install.ps1, version pinned below - keep it older than 72 hours)
# Bump VERSION first; the version is read from it by the project file.
param([switch]$SkipPackage)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
$sdkVersion = '10.0.403'   # released 2026-10-25
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue | ForEach-Object Source
$userDotnet = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
if (Test-Path $userDotnet) { $dotnet = $userDotnet }
if (-not $dotnet -or -not (& $dotnet --list-sdks 2>$null | Where-Object { $_ -match '^10\.' })) {
    Write-Host "No .NET 10 SDK found - installing $sdkVersion into $env:LOCALAPPDATA\Microsoft\dotnet (per user, no admin)..."
    $tmp = Join-Path $env:TEMP 'dotnet-install.ps1'
    Invoke-WebRequest -UseBasicParsing https://dot.net/v1/dotnet-install.ps1 -OutFile $tmp
    & $tmp -Version $sdkVersion -InstallDir (Split-Path $userDotnet) -NoPath
    $dotnet = $userDotnet
}
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'
$proj = Join-Path $root 'src\PCMigration\PCMigration.csproj'
& $dotnet build $proj -c Release -nologo -v q
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed ($LASTEXITCODE)" }
$built = Join-Path $root 'src\PCMigration\bin\Release\net48\PCMigration.exe'
$dist = Join-Path $root 'dist'; New-Item -ItemType Directory -Force -Path $dist | Out-Null
Get-ChildItem $dist -Filter 'PCMigration-*.exe' | Remove-Item -Force
$exe = Join-Path $dist "PCMigration-$version.exe"
Copy-Item -LiteralPath $built -Destination $exe -Force
$fv = (Get-Item $exe).VersionInfo.FileVersion
"$exe  ($([math]::Round((Get-Item $exe).Length / 1KB)) KB, file version $fv)"
if (-not $SkipPackage) { & (Join-Path $root 'Build-Package.ps1') }
