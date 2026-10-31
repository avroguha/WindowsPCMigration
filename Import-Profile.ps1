<#
.SYNOPSIS
  Restores an Export-Profile.ps1 package on the NEW machine: files, HKCU registry, mapped drives, printers,
  user environment variables, VS Code extensions. No admin rights needed.

.DESCRIPTION
  Reads <export folder>\manifest.json (default: the newest folder under OneDrive\PCMigration).
  Every target that already exists is zipped to %LOCALAPPDATA%\PCMigration-backup\<timestamp>\ before it is overwritten,
  so a restore can be undone by hand. Use -WhatIf to see what would happen without touching anything.

  Order of work:
    1. preflight  - OneDrive hydration check, running apps that own settings, username difference
    2. packages   - files (robocopy over the target) and .reg imports, per catalog entry
    3. settings   - user env vars (merge), mapped drives, network printers + default, VS Code extensions
    4. report     - import-<computer>-<date>.md in the export folder

.PARAMETER Source        Export folder (contains manifest.json). Default: newest under OneDrive\PCMigration.
.PARAMETER Include / Exclude   Catalog ids or categories.
.PARAMETER IncludeSecrets Also restore the secrets bundle (asks for the password if it was encrypted).
.PARAMETER NoBackup      Do not back up existing targets first.
.PARAMETER SkipSettings  Skip env vars / drives / printers / extensions.
.PARAMETER RestartExplorer  Restart Explorer at the end so taskbar/Explorer settings show up.
.PARAMETER Force         Do not stop for running apps; just warn.
.PARAMETER RestoreEvenIfMissing  Restore an entry even when its program is not installed yet (normally it is deferred and
                         restore-state-<computer>.json remembers it, so a later run picks it up once the program exists).

.EXAMPLE
  .\Import-Profile.ps1 -WhatIf
.EXAMPLE
  .\Import-Profile.ps1 -Include office,browser -RestartExplorer
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Source,
    [string[]]$Include,
    [string[]]$Exclude,
    [switch]$IncludeSecrets,
    [SecureString]$SecretsPassword,
    [switch]$NoBackup,
    [switch]$SkipPackages,
    [switch]$SkipSettings,
    [switch]$RestartExplorer,
    [switch]$Force,
    [switch]$RestoreEvenIfMissing,
    [string[]]$ForceIds        # restore these entries even if their program is not detected (the wizard passes programs you marked installed)
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'MigrationCommon.psm1') -Force
# The wizard (Migration-UI.ps1) hands the secrets password over in an environment variable of the child process.
if (-not $SecretsPassword -and $env:PCMIG_SECRET_PW) { $SecretsPassword = ConvertTo-SecureString $env:PCMIG_SECRET_PW -AsPlainText -Force; $env:PCMIG_SECRET_PW = $null }

# ---------- locate the export ----------
if (-not $Source) {
    $root = Get-MigRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { throw "No backup folder found (OneDrive\PCMigration or PCMIG_ROOT). Pass -Source <export folder>." }
    $cand = Get-ChildItem -LiteralPath $root -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } | Sort-Object LastWriteTime -Descending
    if (-not $cand) { throw "No export with a manifest.json under $root (has OneDrive finished syncing?)" }
    $Source = $cand[0].FullName
}
$Source = (Resolve-Path -LiteralPath $Source).Path
$manifestPath = Join-Path $Source 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "manifest.json not found in $Source" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$catPath = Join-Path $Source 'catalog.json'; if (-not (Test-Path -LiteralPath $catPath)) { $catPath = Join-Path $scriptDir 'catalog.json' }
$cat = Get-MigCatalog $catPath
$cat = Merge-MigExtraEntries -Catalog $cat -Path (Join-Path $Source 'extra-entries.json')
$catById = @{}; foreach ($e in $cat.entries) { $catById[$e.id] = $e }
if ($ForceIds) { $ForceIds = @($ForceIds | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { $ForceIds = @() }

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
Initialize-MigLog (Join-Path $Source "logs\import-$env:COMPUTERNAME-$stamp.log")
$backupRoot = Join-Path $env:LOCALAPPDATA "PCMigration-backup\$stamp"
$stage = Join-Path $env:LOCALAPPDATA 'Temp\PCMigration-restore'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }
New-Item -ItemType Directory -Force -Path $stage -WhatIf:$false | Out-Null
$oldProfile = "$($manifest.profilePath)"; $newProfile = $env:USERPROFILE
$profileDiffers = ($oldProfile -and ($oldProfile -ne $newProfile))
$dry = $WhatIfPreference

$kitVersion = Get-MigVersion; $backupVersion = "$(Get-Prop $manifest 'kitVersion' 'unknown')"
Write-MigLog "PC Migration kit $kitVersion - Import-Profile on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME (admin: $(Test-MigAdmin))$(if ($dry) { '  [WHAT-IF - nothing will be changed]' })" 'STEP'
Write-MigLog "Backup was made with kit $backupVersion."
if ((Compare-MigVersion $backupVersion $kitVersion) -gt 0) { Write-MigLog "The backup comes from a NEWER kit ($backupVersion) than this one ($kitVersion). Update this copy of the kit before restoring - newer entries may be skipped or restored wrongly." 'WARN' }
Write-MigLog "Source: $Source  (exported from $($manifest.computer) as $($manifest.user) on $($manifest.createdAt))"
$net0 = Test-MigNetwork
Write-MigLog ("Network: {0}; OneDrive client {1}." -f $(if ($net0.Available) { 'connected' } else { 'NOT connected - cloud-only files cannot be read until it is back' }), $(if ($net0.OneDriveRunning) { 'is running' } else { 'is NOT running' }))
if ($profileDiffers) { Write-MigLog "Profile path differs: '$oldProfile' -> '$newProfile'. Paths inside configs and .reg files will be rewritten." 'WARN' }
if (-not $NoBackup) { Write-MigLog "Backups of overwritten targets go to $backupRoot" }

# per-machine restore state: what was restored when, and what is waiting for a program to be installed
$statePath = Join-Path $Source "restore-state-$env:COMPUTERNAME.json"
$state = @{ computer = $env:COMPUTERNAME; entries = @{} }
if (Test-Path -LiteralPath $statePath) {
    try { $sj = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $sj.entries.PSObject.Properties) { $state.entries[$p.Name] = @{ status = "$($p.Value.status)"; at = "$($p.Value.at)"; app = "$($p.Value.app)" } } } catch { }
}
$results = @()
function Add-Result { param([string]$Id, [string]$Status, [string]$Detail = '') $script:results += [pscustomobject]@{ Id = $Id; Status = $Status; Detail = $Detail } }

# ---------- 1. preflight ----------
Write-MigLog 'Phase 1: preflight' 'STEP'
# OneDrive Files On-Demand: a placeholder has the RecallOnDataAccess attribute (0x400000). Reading triggers download,
# but a big batch is better pulled first.
$placeholders = @(Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction SilentlyContinue | Where-Object { ([int]$_.Attributes -band 0x400000) -ne 0 })
if ($placeholders.Count -gt 0) {
    Write-MigLog "$($placeholders.Count) file(s) in the export are OneDrive placeholders (not downloaded yet). Right-click the folder > 'Always keep on this device', wait, then re-run. Continuing anyway - each file is fetched on first read, which can be slow." 'WARN'
}
$entries = Select-MigEntries -Catalog $cat -Include $Include -Exclude $Exclude
$wanted = @{}; foreach ($e in $entries) { $wanted[$e.id] = $true }
$pkgs = @($manifest.entries | Where-Object { $wanted.ContainsKey($_.id) })
$secretPkgs = @()
if ($IncludeSecrets) { $secretPkgs = @($manifest.secrets | Where-Object { $wanted.ContainsKey($_.id) }) }
Write-MigLog "Packages to restore: $($pkgs.Count) regular, $($secretPkgs.Count) secret"

# apps that hold the files we are about to overwrite
$procMap = @{ 'Notepad' = 'win-notepad-tabs'; 'msedge' = 'browser-edge'; 'chrome' = 'browser-chrome'; 'firefox' = 'browser-firefox'; 'opera' = 'browser-opera'; 'Code' = 'dev-vscode'; 'Cursor' = 'dev-cursor'; 'notepad++' = 'dev-notepadpp'; 'OUTLOOK' = 'office-'; 'EXCEL' = 'office-'; 'WINWORD' = 'office-'; 'POWERPNT' = 'office-'; 'ONENOTE' = 'office-'; 'putty' = 'tools-putty'; 'WinSCP' = 'tools-winscp'; 'MobaXterm' = 'tools-mobaxterm'; 'SecureCRT' = 'tools-securecrt'; 'Xshell' = 'tools-xshell'; 'WindowsTerminal' = 'dev-windows-terminal'; 'dbeaver' = 'data-dbeaver'; 'Ssms' = 'data-ssms'; 'idea64' = 'dev-jetbrains'; 'pycharm64' = 'dev-jetbrains'; 'datagrip64' = 'dev-jetbrains'; 'devenv' = 'dev-visualstudio'; 'PowerToys' = 'tools-powertoys'; 'Microsoft.Notes' = 'win-sticky-notes'; 'Postman' = 'data-postman'; 'PBIDesktop' = 'data-power-bi'; 'KeePass' = 'tools-keepass'; 'Greenshot' = 'tools-greenshot'; 'ShareX' = 'tools-sharex'; 'Snagit32' = 'tools-snagit'; 'SnagitEditor' = 'tools-snagit'; 'claude' = 'dev-claude-desktop' }
$running = @()
foreach ($pn in $procMap.Keys) {
    if (Get-Process -Name $pn -ErrorAction SilentlyContinue) {
        $hit = @($pkgs + $secretPkgs | Where-Object { $_.id -like ($procMap[$pn] + '*') })
        if ($hit.Count -gt 0) { $running += "$pn ($(($hit | ForEach-Object { $_.id }) -join ', '))" }
    }
}
if ($running.Count -gt 0) {
    Write-MigLog "Running apps own settings about to be restored: $($running -join '; ')" 'WARN'
    if (-not $Force -and -not $dry) {
        $ans = Read-Host 'Close them and press Enter to continue, or type S to skip those entries, or Q to quit'
        if ($ans -match '^q') { return }
        if ($ans -match '^s') {
            foreach ($pn in $procMap.Keys) { if (Get-Process -Name $pn -ErrorAction SilentlyContinue) { $pkgs = @($pkgs | Where-Object { $_.id -notlike ($procMap[$pn] + '*') }); $secretPkgs = @($secretPkgs | Where-Object { $_.id -notlike ($procMap[$pn] + '*') }) } }
        }
    }
}

# secrets password
if ($secretPkgs.Count -gt 0 -and $manifest.secretsEncrypted -and -not $SecretsPassword) {
    $SecretsPassword = Read-Host -AsSecureString 'Password of the secrets bundle'
}

# ---------- 2. packages ----------
function Backup-Target {
    param([string]$Id, [int]$Index, [string]$Target)
    if ($NoBackup -or -not (Test-Path -LiteralPath $Target)) { return }
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $zip = Join-Path $backupRoot ("{0}-{1}.zip" -f $Id, $Index)
    $it = Get-Item -LiteralPath $Target -Force
    if ($it.PSIsContainer) {
        try { Compress-MigDirectory -Source $Target -Zip $zip } catch { Write-MigLog "  backup of $Target failed: $($_.Exception.Message)" 'WARN' }
    } else {
        $bd = Join-Path $backupRoot ("{0}-{1}" -f $Id, $Index); New-Item -ItemType Directory -Force -Path $bd | Out-Null
        Copy-Item -LiteralPath $Target -Destination $bd -Force
    }
}

function Restore-Package {
    param($Pkg, [bool]$IsSecret)
    $id = $Pkg.id
    $entry = $catById[$id]
    $zipRel = "$($Pkg.zip)"
    $zip = Join-Path $Source $zipRel
    if (-not (Test-Path -LiteralPath $zip)) { Add-Result $id 'missing' "package file not found: $zipRel"; Write-MigLog "${id}: package missing ($zipRel)" 'WARN'; return }
    $work = Join-Path $stage $id
    $plainZip = $zip
    if ($IsSecret -and (Get-Prop $Pkg 'encrypted' $false)) {
        if (-not $SecretsPassword) { Add-Result $id 'skipped' 'encrypted, no password'; return }
        $plainZip = Join-Path $stage "$id.zip"
        if (-not $dry) { try { Unprotect-MigFile -Path $zip -OutFile $plainZip -Password $SecretsPassword } catch { Add-Result $id 'failed' "decrypt: $($_.Exception.Message)"; Write-MigLog "${id}: decrypt failed (wrong password?)" 'ERROR'; return } }
    }
    if (-not $dry) {
        # cloud-only OneDrive files or a share can drop away mid-restore: wait and retry instead of failing the entry
        $tries = 0
        while ($true) {
            $tries++
            if (-not (Wait-MigReachable -Path $plainZip -Mode read -What "the backup package $zipRel")) { Add-Result $id 'failed' 'backup unreachable'; return }
            try { Expand-MigArchive -Zip $plainZip -Destination $work; break }
            catch { if ($tries -ge 3) { throw }; Write-MigLog "${id}: reading the package failed ($($_.Exception.Message)) - retrying in 15 s" 'WAIT'; Start-Sleep -Seconds 15 }
        }
    }
    $kind = "$($Pkg.kind)"
    $detail = @()
    if ($kind -eq 'files') {
        foreach ($item in $Pkg.items) {
            $target = Expand-MigPath "$($item.token)"
            if ($profileDiffers -and $target.StartsWith($oldProfile, [StringComparison]::OrdinalIgnoreCase)) { $target = $newProfile + $target.Substring($oldProfile.Length) }
            $src = Join-Path $work "$($item.index)"
            if ("$($item.type)" -eq 'dir') {
                if ($PSCmdlet.ShouldProcess($target, "restore folder from $id (index $($item.index))")) {
                    Backup-Target $id $item.index $target
                    if ($profileDiffers) { $n = Update-MigProfilePaths -Root $src -OldProfile $oldProfile -NewProfile $newProfile; if ($n) { $detail += "rewrote old profile path in $n file(s)" } }
                    New-Item -ItemType Directory -Force -Path $target | Out-Null
                    $r = Invoke-MigRobocopy -Source $src -Destination $target -Overwrite
                    if ($r.Ok) { $detail += "$($r.Files) files -> $target" } else { $detail += "FAILED ($($r.Failed) files) -> $target : $($r.Output)" }
                } else { $detail += "would restore folder -> $target" }
            } else {
                $file = if (-not $dry) { Get-ChildItem -LiteralPath $src -File | Select-Object -First 1 } else { $null }
                if ($PSCmdlet.ShouldProcess($target, "restore file from $id")) {
                    Backup-Target $id $item.index $target
                    if ($profileDiffers) { [void](Update-MigProfilePaths -Root $src -OldProfile $oldProfile -NewProfile $newProfile) }
                    $tdir = Split-Path -Parent $target; if (-not (Test-Path -LiteralPath $tdir)) { New-Item -ItemType Directory -Force -Path $tdir | Out-Null }
                    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
                    $detail += "file -> $target"
                } else { $detail += "would restore file -> $target" }
            }
        }
    } else {
        $waitingVendors = @(); $doneVendors = @()
        foreach ($item in $Pkg.items) {
            $regFile = Join-Path $work "$($item.file)"
            $key = "$($item.key)"
            $vendor = "$(Get-Prop $item 'vendor' '')"
            if ($vendor -and -not $RestoreEvenIfMissing -and -not (Test-MigVendorInstalled $vendor)) { $waitingVendors += $vendor; continue }
            if ($vendor) { $doneVendors += $vendor }
            if ($PSCmdlet.ShouldProcess($key, "import registry from $id")) {
                $r = Import-MigRegistry -File $regFile -OldProfile $oldProfile -NewProfile $newProfile
                if ($r.Ok) { $detail += "imported $key" } else { $detail += "FAILED $key : $($r.Output)" }
                if ($r.HexPathsLeft -gt 0) { $detail += "$($r.HexPathsLeft) REG_EXPAND_SZ/binary value(s) still hold the old profile path (check $key)" }
            } else { $detail += "would import $key" }
        }
        if ($waitingVendors.Count -gt 0) {
            $detail = @("imported $($doneVendors.Count) key(s)$(if ($doneVendors.Count) { ': ' + ($doneVendors -join ', ') })", "waiting for $($waitingVendors -join ', ') to be installed")
            Add-Result $id 'deferred' ($detail -join '; ')
            Write-MigLog ("{0,-28} {1,-8} {2}" -f $id, 'wait', ($detail -join '; ')) 'WAIT'
            if (-not $dry) { $state.entries["$id"] = @{ status = 'deferred'; at = (Get-Date).ToString('o'); app = ($waitingVendors -join ', ') }; Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
            return
        }
    }
    $status = if ($dry) { 'what-if' } elseif ($detail -match 'FAILED') { 'partial' } else { 'ok' }
    Add-Result $id $status ($detail -join '; ')
    Write-MigLog ("{0,-28} {1,-8} {2}" -f $id, $status, ($detail -join '; ')) $(if ($status -eq 'partial') { 'WARN' } else { 'OK' })
    if (-not $dry) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue; if ($plainZip -ne $zip) { Remove-Item -LiteralPath $plainZip -Force -ErrorAction SilentlyContinue } }
}

if (-not $SkipPackages) {
    Write-MigLog 'Phase 2: packages' 'STEP'
    # files first, registry after (fonts/taskbar registry refer to files)
    # entries whose program is not installed yet are deferred (unless -RestoreEvenIfMissing)
    $deferred = @{}
    foreach ($p in @($pkgs) + @($secretPkgs)) {
        $entry = $catById["$($p.id)"]; if (-not $entry) { continue }
        $inst = Test-MigAppInstalled $entry
        if ($inst -eq $false -and -not $RestoreEvenIfMissing -and ($ForceIds -notcontains "$($p.id)")) {
            $app = Get-MigAppName $entry
            $deferred["$($p.id)"] = $app
            Add-Result $p.id 'deferred' "waiting for $app to be installed"
            Write-MigLog ("{0,-28} {1,-8} waiting for {2} to be installed - run again after installing it" -f $p.id, 'wait', $app) 'WAIT'
            if (-not $dry) { $state.entries["$($p.id)"] = @{ status = 'deferred'; at = (Get-Date).ToString('o'); app = $app } }
        }
    }
    $pkgs = @($pkgs | Where-Object { -not $deferred.ContainsKey("$($_.id)") }); $secretPkgs = @($secretPkgs | Where-Object { -not $deferred.ContainsKey("$($_.id)") })
    foreach ($p in ($pkgs | Where-Object { "$($_.kind)" -eq 'files' })) { try { Restore-Package $p $false } catch { Add-Result $p.id 'failed' $_.Exception.Message; Write-MigLog "$($p.id) FAILED: $($_.Exception.Message)" 'ERROR' } }
    foreach ($p in ($pkgs | Where-Object { "$($_.kind)" -ne 'files' })) { try { Restore-Package $p $false } catch { Add-Result $p.id 'failed' $_.Exception.Message; Write-MigLog "$($p.id) FAILED: $($_.Exception.Message)" 'ERROR' } }
    foreach ($p in $secretPkgs) { try { Restore-Package $p $true } catch { Add-Result $p.id 'failed' $_.Exception.Message; Write-MigLog "$($p.id) FAILED: $($_.Exception.Message)" 'ERROR' } }
    if (-not $dry) { foreach ($r in $results) { if ($r.Status -in 'ok', 'partial') { $state.entries[$r.Id] = @{ status = 'restored'; at = (Get-Date).ToString('o'); app = '' } } } }
}

# ---------- 3. settings from the inventory ----------
if (-not $SkipSettings) {
    Write-MigLog 'Phase 3: environment, drives, printers, extensions' 'STEP'
    $inv = Join-Path $Source 'inventory'

    # user environment variables: add missing ones, merge PATH entries whose folder exists
    $envFile = Join-Path $inv 'env-user.json'
    if (Test-Path -LiteralPath $envFile) {
        $ej = Get-Content -LiteralPath $envFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $added = @(); $pathAdded = @(); $pathSkipped = @()
        foreach ($p in $ej.variables.PSObject.Properties) {
            $name = $p.Name; $val = "$($p.Value)"
            if ($name -in 'Path', 'TEMP', 'TMP', 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer') { continue }
            if ($profileDiffers) { $val = $val -replace [regex]::Escape($oldProfile), $newProfile }
            $cur = [Environment]::GetEnvironmentVariable($name, 'User')
            if ($null -eq $cur) {
                if ($PSCmdlet.ShouldProcess("user env $name", "set to '$val'")) { [Environment]::SetEnvironmentVariable($name, $val, 'User'); $added += $name }
            }
        }
        # read the raw (unexpanded) user PATH so %VAR% entries survive the round trip
        $envKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
        $rawPath = if ($envKey) { "$($envKey.GetValue('Path', '', 'DoNotExpandEnvironmentNames'))" } else { '' }
        $curPath = @($rawPath.Split(';') | Where-Object { $_ })
        $curExpanded = @($curPath | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\').ToLower() })
        foreach ($pe in @($ej.pathEntries)) {
            $pe2 = "$pe"; if ($profileDiffers) { $pe2 = $pe2 -replace [regex]::Escape($oldProfile), $newProfile }
            $resolved = [Environment]::ExpandEnvironmentVariables($pe2)
            if ($curExpanded -contains $resolved.TrimEnd('\').ToLower()) { continue }
            if (Test-Path -LiteralPath $resolved) { $curPath += $pe2; $pathAdded += $pe2 } else { $pathSkipped += $pe2 }
        }
        if ($pathAdded.Count -gt 0 -and $PSCmdlet.ShouldProcess('user PATH', "append $($pathAdded -join ';')")) {
            # write back as REG_EXPAND_SZ through reg.exe (SetEnvironmentVariable would store REG_SZ and freeze %VAR%s)
            $null = & reg.exe add 'HKCU\Environment' /v Path /t REG_EXPAND_SZ /d ($curPath -join ';') /f 2>&1
        }
        Write-MigLog "Env: added $($added.Count) variable(s) [$($added -join ', ')]; PATH +$($pathAdded.Count); $($pathSkipped.Count) PATH entries skipped because the folder does not exist yet (install the app, then re-run): $($pathSkipped -join '; ')"
        Add-Result 'env-user' 'ok' "vars +$($added.Count), PATH +$($pathAdded.Count), skipped $($pathSkipped.Count)"
    }

    # mapped drives
    $drvFile = Join-Path $inv 'mapped-drives.csv'
    if ((Test-Path -LiteralPath $drvFile) -and (Get-Item -LiteralPath $drvFile).Length -gt 0) {
        foreach ($d in (Import-Csv -LiteralPath $drvFile)) {
            $letter = "$($d.Letter)".TrimEnd(':').ToUpper()
            if (Test-Path -LiteralPath "${letter}:\") { Write-MigLog "Drive ${letter}: already in use - skipped ($($d.RemotePath))"; continue }
            if ($PSCmdlet.ShouldProcess("${letter}: -> $($d.RemotePath)", 'map persistent drive')) {
                $o = & net.exe use "${letter}:" "$($d.RemotePath)" /persistent:yes 2>&1
                if ($LASTEXITCODE -eq 0) { Write-MigLog "Mapped ${letter}: -> $($d.RemotePath)" 'OK' } else { Write-MigLog "Map ${letter}: -> $($d.RemotePath) failed: $o" 'WARN' }
            }
        }
    }

    # network printers + default
    $prFile = Join-Path $inv 'printers.csv'
    if ((Test-Path -LiteralPath $prFile) -and (Get-Item -LiteralPath $prFile).Length -gt 0) {
        $prs = Import-Csv -LiteralPath $prFile
        $have = @(Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        foreach ($p in ($prs | Where-Object { $_.Type -eq 'Connection' -and $_.Name -like '\\*' })) {
            if ($have -contains $p.Name) { continue }
            if ($PSCmdlet.ShouldProcess($p.Name, 'add network printer')) {
                try { Add-Printer -ConnectionName $p.Name -ErrorAction Stop; Write-MigLog "Added printer $($p.Name)" 'OK' } catch { Write-MigLog "Add printer $($p.Name) failed: $($_.Exception.Message)" 'WARN' }
            }
        }
        $def = $prs | Where-Object { "$($_.Default)" -eq 'True' } | Select-Object -First 1
        if ($def -and $PSCmdlet.ShouldProcess($def.Name, 'set default printer')) {
            try { (New-Object -ComObject WScript.Network).SetDefaultPrinter($def.Name); Write-MigLog "Default printer: $($def.Name)" 'OK' } catch { Write-MigLog "Default printer $($def.Name) not set: $($_.Exception.Message)" 'WARN' }
        }
        $local = @($prs | Where-Object { $_.Type -ne 'Connection' -and $_.Name -notmatch 'Microsoft|OneNote|Fax|PDF|XPS' })
        if ($local.Count -gt 0) { Write-MigLog "Local/IP printers need a driver (admin or portal): $(($local | ForEach-Object { "$($_.Name) [$($_.Driver) on $($_.Port)]" }) -join '; ')" 'WARN' }
    }

    # VS Code-family extensions
    $vsFile = Join-Path $inv 'vscode-extensions.txt'
    if (Test-Path -LiteralPath $vsFile) {
        $lines = @(Get-Content -LiteralPath $vsFile | Where-Object { $_ -match '^\S+\s+\S+' })
        $byCmd = $lines | Group-Object { ($_ -split '\s+')[0] }
        foreach ($g in $byCmd) {
            $cmd = Get-Command $g.Name -ErrorAction SilentlyContinue
            if (-not $cmd) { Write-MigLog "$($g.Name) not on PATH - $($g.Count) extension(s) listed in inventory\vscode-extensions.txt; install the editor and re-run with -Include none -SkipPackages" 'WARN'; continue }
            $installed = @()
            try { $installed = @(& $g.Name --list-extensions 2>$null | Where-Object { $_ -match '^\S+\.\S+$' }) } catch { }
            if ($installed.Count -eq 0) {
                # the CLI said nothing (busy editor, broken shim): read the extensions folder instead
                $extDir = @{ 'code' = "$env:USERPROFILE\.vscode\extensions"; 'code-insiders' = "$env:USERPROFILE\.vscode-insiders\extensions"; 'cursor' = "$env:USERPROFILE\.cursor\extensions" }[$g.Name]
                if ($extDir -and (Test-Path -LiteralPath $extDir)) { $installed = @(Get-ChildItem -LiteralPath $extDir -Directory | ForEach-Object { $_.Name -replace '-\d+(\.\d+)*(-\w+)?$', '' }) }
            }
            $todo = @($g.Group | ForEach-Object { ($_ -split '\s+')[1] } | Where-Object { $installed -notcontains $_ })
            if ($todo.Count -eq 0) { Write-MigLog "$($g.Name): all $($g.Count) extensions already present"; continue }
            if ($PSCmdlet.ShouldProcess("$($g.Name)", "install $($todo.Count) extensions")) {
                $ok = 0; $fails = @()
                foreach ($x in $todo) {
                    # each install gets 3 minutes; a hung marketplace call must never stall the whole restore
                    $tmpOut = Join-Path $env:TEMP ('migext-' + [guid]::NewGuid().ToString('N') + '.txt')
                    try {
                        $pr = Start-Process -FilePath $cmd.Source -ArgumentList "--install-extension $x --force" -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError ($tmpOut + '.err')
                        $null = $pr.Handle
                        if (-not $pr.WaitForExit(180000)) { try { $pr.Kill() } catch { }; $fails += "$x (timed out)" }
                        elseif ($pr.ExitCode -eq 0) { $ok++ } else { $fails += "$x (exit $($pr.ExitCode))" }
                    } catch { $fails += "$x ($($_.Exception.Message))" }
                    Remove-Item -LiteralPath $tmpOut, ($tmpOut + '.err') -Force -ErrorAction SilentlyContinue
                }
                if ($fails.Count -gt 0) { Write-MigLog "$($g.Name): $($fails.Count) extension(s) not installed - $($fails -join ', ') (install them from the Extensions view; the list is in inventory\vscode-extensions.txt)" 'WARN' }
                Write-MigLog "$($g.Name): installed $ok/$($todo.Count) extensions" 'OK'
            }
        }
    }
}

Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue

# ---------- 4. report ----------
$needRestart = @($pkgs | Where-Object { "$($_.needsRestart)" } | ForEach-Object { "$($_.needsRestart)" } | Sort-Object -Unique)
$rep = New-Object System.Collections.Generic.List[string]
$rep.Add("# Import on $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm')$(if ($dry) { ' (WHAT-IF, nothing changed)' }) - kit $kitVersion (backup made with $backupVersion)")
$rep.Add(''); $rep.Add("Source: ``$Source`` (from $($manifest.computer))"); $rep.Add("Backups: ``$backupRoot``"); $rep.Add('')
$rep.Add('| id | status | detail |'); $rep.Add('|---|---|---|')
foreach ($r in $results) { $rep.Add("| ``$($r.Id)`` | $($r.Status) | $($r.Detail -replace '\|', '/') |") }
$waiting = @($results | Where-Object Status -eq 'deferred')
if ($waiting.Count -gt 0) {
    $rep.Add(''); $rep.Add('## Install these programs, then run the restore again'); $rep.Add('')
    foreach ($w in ($waiting | Sort-Object Detail)) { $rep.Add("- $($w.Detail -replace '^waiting for ', '' -replace ' to be installed$', '')  (for ``$($w.Id)``)") }
    $rep.Add(''); $rep.Add('The restore remembers these in `restore-state-' + $env:COMPUTERNAME + '.json` and picks them up automatically on the next run.')
}
$rep.Add(''); $rep.Add('## Next')
$rep.Add("- $(if ($needRestart -contains 'signout') { 'Sign out and back in' } elseif ($needRestart -contains 'explorer') { 'Restart Explorer (or sign out/in)' } else { 'No restart needed' }) for shell settings to apply.")
$rep.Add('- Open `report.md` in the export folder and work through "Manual steps".')
if (Test-Path -LiteralPath (Join-Path $Source 'inventory\browser-extensions.md')) { $rep.Add('- Browser extensions: open each browser once; if any extension is missing or disabled, `inventory\browser-extensions.md` has a store link for every one.') }
$rep.Add('- Run `Compare-Software.cmd` again after installing from the portal to confirm nothing is missing.')
$repPath = Join-Path $Source "import-$env:COMPUTERNAME-$stamp.md"
if (-not $dry) {
    Set-Content -LiteralPath $repPath -Value $rep -Encoding UTF8
    try { @{ computer = $state.computer; updatedAt = (Get-Date).ToString('o'); entries = $state.entries } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8 } catch { Write-MigLog "Could not write $statePath : $($_.Exception.Message)" 'WARN' }
} else { $rep | ForEach-Object { Write-Host $_ } }

$okN = @($results | Where-Object Status -eq 'ok').Count; $badN = @($results | Where-Object { $_.Status -in 'partial', 'failed', 'missing' }).Count
Write-MigLog "Done: $okN ok, $badN with problems, $(@($results | Where-Object Status -eq 'deferred').Count) waiting for a program to be installed, $(@($results | Where-Object Status -eq 'skipped').Count) skipped.$(if (-not $dry) { " Report: $repPath" })" 'STEP'
if ($needRestart.Count -gt 0) {
    if ($RestartExplorer -and -not $dry -and $PSCmdlet.ShouldProcess('explorer.exe', 'restart')) { Stop-Process -Name explorer -Force; Start-Sleep 2; if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe } }
    else { Write-MigLog "Restored settings need: $($needRestart -join ' + '). Sign out and back in (or re-run with -RestartExplorer)." 'WARN' }
}
