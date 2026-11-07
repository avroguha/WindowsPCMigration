<#
.SYNOPSIS
  Captures everything a standard (non-admin) user can carry from this Windows PC into a OneDrive folder:
  software inventory, user-level settings (files + HKCU registry), and a discovery list of what was NOT covered.

.DESCRIPTION
  Run on the OLD machine. No admin rights, no USB, no network share needed - the output lands in OneDrive and
  syncs to the new machine, where Import-Profile.ps1 and Compare-Software.ps1 use it.

  Output folder (default):  <OneDrive>\PCMigration\<COMPUTERNAME>-<user>-<yyyyMMdd-HHmm>\
    manifest.json        what was packaged (ids, source paths, sizes) - read by Import-Profile
    catalog.json         the catalog used (copied, so import does not depend on the repo version)
    report.md            human-readable summary + manual to-do list
    inventory\           software.csv, store-apps.csv, portable-apps.csv, env-user.json, mapped-drives.csv,
                         printers.csv, startup.csv, scheduled-tasks.csv, credential-targets.txt, default-apps.csv,
                         browser-extensions.csv, vscode-extensions.txt, ps-modules.csv, office.json, tool-versions.txt ...
    discovery\           every AppData / profile folder with size, last-write and whether the catalog covers it
    packages\<id>.zip    one zip per catalog entry (files and/or .reg exports)
    secrets\<id>.zip.enc encrypted secret entries (only with -IncludeSecrets)
    logs\export.log

.PARAMETER Destination   Output folder. Default: OneDrive\PCMigration\<computer>-<user>-<timestamp>
.PARAMETER Include       Catalog ids or categories to export (default: everything non-secret)
.PARAMETER Exclude       Catalog ids or categories to skip
.PARAMETER IncludeSecrets  Also export entries marked secret (SSH keys, tokens, saved logins)
.PARAMETER SecretsPassword Password used to AES-encrypt the secrets zips. Prompted if -IncludeSecrets without it.
.PARAMETER MaxFileMB     Per-file size cap inside packages (default 500). Larger files are listed in the report.
.PARAMETER SkipInventory / SkipDiscovery / SkipPackages  Skip a phase.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Export-Profile.ps1
.EXAMPLE
  .\Export-Profile.ps1 -Include browser,office -IncludeSecrets
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [string[]]$Include,
    [string[]]$Exclude,
    [switch]$IncludeSecrets,
    [SecureString]$SecretsPassword,
    [int]$MaxFileMB = 500,
    [switch]$SkipInventory,
    [switch]$SkipDiscovery,
    [switch]$SkipPackages,
    [string]$Catalog,
    [string]$ExtraEntries      # json with additional catalog entries for this backup (the wizard writes <Destination>\extra-entries.json)
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Catalog) { $Catalog = Join-Path $scriptDir 'catalog.json' }
Import-Module (Join-Path $scriptDir 'MigrationCommon.psm1') -Force
# The app (PCMigration.exe) hands the secrets password over in an environment variable of the child process.
if (-not $SecretsPassword -and $env:PCMIG_SECRET_PW) { $SecretsPassword = ConvertTo-SecureString $env:PCMIG_SECRET_PW -AsPlainText -Force; $env:PCMIG_SECRET_PW = $null }

# ---------- destination ----------
if (-not $Destination) {
    $migRoot = Get-MigRoot
    if (-not $migRoot) { throw "OneDrive folder not found. Pass -Destination, or set PCMIG_ROOT to a folder/share both computers can reach." }
    $Destination = Join-Path $migRoot ('{0}-{1}-{2}' -f $env:COMPUTERNAME, $env:USERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
}
foreach ($d in 'inventory', 'discovery', 'packages', 'secrets', 'logs') { New-Item -ItemType Directory -Force -Path (Join-Path $Destination $d) | Out-Null }
Initialize-MigLog (Join-Path $Destination 'logs\export.log')
$stage = Join-Path $env:LOCALAPPDATA 'Temp\PCMigration-stage'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$cat = Get-MigCatalog $Catalog
Copy-Item -LiteralPath $Catalog -Destination (Join-Path $Destination 'catalog.json') -Force
if (-not $ExtraEntries) { $ExtraEntries = Join-Path $Destination 'extra-entries.json' }
if (Test-Path -LiteralPath $ExtraEntries) {
    $cat = Merge-MigExtraEntries -Catalog $cat -Path $ExtraEntries
    if ((Resolve-Path -LiteralPath $ExtraEntries).Path -ne (Join-Path $Destination 'extra-entries.json')) { Copy-Item -LiteralPath $ExtraEntries -Destination (Join-Path $Destination 'extra-entries.json') -Force }
    Write-MigLog "Extra entries for this backup: $(@((Get-Content -LiteralPath $ExtraEntries -Raw | ConvertFrom-Json).entries).Count) (discovered data folders / folders you added)"
}
$started = Get-Date
$kitVersion = Get-MigVersion
Write-MigLog "PC Migration kit $kitVersion - Export-Profile on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME (admin: $(Test-MigAdmin))" 'STEP'
Write-MigLog "Destination: $Destination"
$net0 = Test-MigNetwork
Write-MigLog ("Network: {0}{1}; OneDrive client {2}. Packing into a local OneDrive folder does not need the network - the upload happens afterwards." -f $(if ($net0.Available) { 'connected' } else { 'NOT connected' }), $(if ($net0.Profiles.Count) { ' - ' + ($net0.Profiles -join '; ') } else { '' }), $(if ($net0.OneDriveRunning) { 'is running' } else { 'is NOT running - start it before the new PC needs the files' }))
if (-not (Wait-MigReachable -Path $Destination -Mode write -TimeoutMinutes 30 -What 'the backup folder')) { throw "Backup folder unreachable: $Destination" }

# Unsaved work exists on disk only once the editor has written its recovery files, and open apps lock files.
$editorMap = @{ 'Postman' = 'Postman'; 'MobaXterm' = 'MobaXterm'; 'Notepad' = 'Notepad'; 'notepad++' = 'Notepad++'; 'Code' = 'VS Code'; 'WINWORD' = 'Word'; 'EXCEL' = 'Excel'; 'POWERPNT' = 'PowerPoint'; 'OUTLOOK' = 'Outlook'; 'msedge' = 'Edge'; 'chrome' = 'Chrome'; 'firefox' = 'Firefox' }
$openEditors = @($editorMap.Keys | Where-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue } | ForEach-Object { $editorMap[$_] } | Sort-Object -Unique)
if ($openEditors.Count -gt 0) { Write-MigLog "Still open: $($openEditors -join ', '). Unsaved tabs/documents are carried only if the program has written them to disk - save your work and close these before packing, then re-run with -Include <id> for their entries." 'WARN' }

$manifest = [ordered]@{
    version      = 1
    kitVersion   = $kitVersion
    createdAt    = $started.ToString('o')
    computer     = $env:COMPUTERNAME
    user         = $env:USERNAME
    domain       = $env:USERDOMAIN
    profilePath  = $env:USERPROFILE
    oneDrive     = (Get-MigOneDriveRoot)
    os           = "$([Environment]::OSVersion.VersionString)"
    maxFileMB    = $MaxFileMB
    entries      = @()
    secrets      = @()
    secretsEncrypted = $false
    skipped      = @()
}
$report = New-Object System.Collections.Generic.List[string]
$manual = New-Object System.Collections.Generic.List[string]

function Save-Csv { param($Data, [string]$Name) $p = Join-Path $Destination "inventory\$Name"; if ($Data) { $Data | Export-Csv -LiteralPath $p -NoTypeInformation -Encoding UTF8 } else { Set-Content -LiteralPath $p -Value '' -Encoding UTF8 } }
function Save-Text { param([string[]]$Lines, [string]$Name) Set-Content -LiteralPath (Join-Path $Destination "inventory\$Name") -Value $Lines -Encoding UTF8 }
function Save-Json { param($Data, [string]$Name) $Data | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Destination "inventory\$Name") -Encoding UTF8 }
function Try-Cmd { param([string]$Label, [scriptblock]$Block) try { & $Block } catch { Write-MigLog "$Label failed: $($_.Exception.Message)" 'WARN'; $null } }

# =====================================================================================
# 1. INVENTORY
# =====================================================================================
if (-not $SkipInventory) {
    Write-MigLog 'Phase 1: inventory' 'STEP'

    # --- system facts ---
    $os = Try-Cmd 'OS' { Get-CimInstance Win32_OperatingSystem }
    $cs = Try-Cmd 'ComputerSystem' { Get-CimInstance Win32_ComputerSystem }
    $sys = [ordered]@{
        computer = $env:COMPUTERNAME; user = $env:USERNAME; domain = $env:USERDOMAIN; profile = $env:USERPROFILE
        osCaption = $(if ($os) { $os.Caption } else { '' }); osBuild = $(if ($os) { $os.BuildNumber } else { '' }); osVersion = "$([Environment]::OSVersion.Version)"
        manufacturer = $(if ($cs) { $cs.Manufacturer } else { '' }); model = $(if ($cs) { $cs.Model } else { '' })
        ramGB = $(if ($cs) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { 0 })
        timeZone = (Get-TimeZone).Id; culture = (Get-Culture).Name; uiCulture = (Get-UICulture).Name
        oneDrive = $env:OneDrive; oneDriveCommercial = $env:OneDriveCommercial
        documents = [Environment]::GetFolderPath('MyDocuments'); desktop = [Environment]::GetFolderPath('Desktop')
        dpiScaling = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).LogPixels
        displays = @(Try-Cmd 'Displays' { Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name) $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" } })
        isAdmin = (Test-MigAdmin)
    }
    Save-Json $sys 'system.json'
    Write-MigLog "System: $($sys.osCaption) build $($sys.osBuild), $($sys.manufacturer) $($sys.model)"

    # --- installed software ---
    $sw = Get-InstalledSoftware
    Save-Csv $sw 'software.csv'
    Write-MigLog "Installed software: $($sw.Count) entries ($(@($sw | Where-Object Scope -like 'User*').Count) per-user)"
    $store = Get-StoreApps
    Save-Csv $store 'store-apps.csv'
    Write-MigLog "Store / Appx apps: $($store.Count)"
    $portable = Get-PortableApps
    Save-Csv $portable 'portable-apps.csv'
    Write-MigLog "Per-user / portable program folders: $($portable.Count)"
    $winget = Try-Cmd 'winget' { if (Get-Command winget -ErrorAction SilentlyContinue) { & winget list --accept-source-agreements --disable-interactivity 2>$null } }
    if ($winget) { Save-Text $winget 'winget-list.txt' }

    # --- user environment variables ---
    $envKey = Get-Item 'HKCU:\Environment'
    $envVars = [ordered]@{}
    foreach ($n in $envKey.GetValueNames()) { $envVars[$n] = $envKey.GetValue($n, $null, 'DoNotExpandEnvironmentNames') }
    $userPath = @(); if ($envVars.Contains('Path')) { $userPath = @("$($envVars['Path'])".Split(';') | Where-Object { $_ }) }
    Save-Json ([ordered]@{ variables = $envVars; pathEntries = $userPath }) 'env-user.json'
    Write-MigLog "User environment: $($envVars.Count) variables, $($userPath.Count) PATH entries"

    # --- mapped drives ---
    $drives = @()
    if (Test-Path 'HKCU:\Network') {
        Get-ChildItem 'HKCU:\Network' | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath
            $drives += [pscustomobject]@{ Letter = $_.PSChildName.ToUpper(); RemotePath = (Get-Prop $p 'RemotePath' ''); UserName = (Get-Prop $p 'UserName' ''); Provider = (Get-Prop $p 'ProviderName' ''); Source = 'persistent' }
        }
    }
    Try-Cmd 'net use' { & net.exe use 2>$null | ForEach-Object { if ($_ -match '^\s*(OK|Disconnected|Unavailable)\s+([A-Z]:)\s+(\\\\\S+)') { if (-not ($drives | Where-Object Letter -eq $matches[2])) { $drives += [pscustomobject]@{ Letter = $matches[2]; RemotePath = $matches[3]; UserName = ''; Provider = ''; Source = 'session' } } } } }
    Save-Csv $drives 'mapped-drives.csv'
    Write-MigLog "Mapped drives: $($drives.Count)"

    # --- printers ---
    $printers = @()
    Try-Cmd 'printers' {
        $defaultName = (Get-CimInstance Win32_Printer | Where-Object Default | Select-Object -First 1).Name
        Get-Printer -ErrorAction Stop | ForEach-Object {
            $printers += [pscustomobject]@{ Name = $_.Name; Type = "$($_.Type)"; Driver = $_.DriverName; Port = $_.PortName; Computer = $_.ComputerName; Shared = $_.Shared; Default = ($_.Name -eq $defaultName) }
        }
    }
    Save-Csv $printers 'printers.csv'
    Write-MigLog "Printers: $($printers.Count) (network: $(@($printers | Where-Object Type -eq 'Connection').Count))"

    # --- startup items ---
    $startup = @()
    foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce') {
        if (Test-Path $k) { $it = Get-Item $k; foreach ($n in $it.GetValueNames()) { $startup += [pscustomobject]@{ Source = $k.Replace('HKCU:\Software\Microsoft\Windows\CurrentVersion\', 'HKCU '); Name = $n; Command = $it.GetValue($n) } } }
    }
    $sf = [Environment]::GetFolderPath('Startup'); if (Test-Path $sf) { Get-ChildItem $sf -File | ForEach-Object { $startup += [pscustomobject]@{ Source = 'Startup folder'; Name = $_.Name; Command = $_.FullName } } }
    Save-Csv $startup 'startup.csv'

    # --- scheduled tasks owned by this user ---
    $tasks = @()
    Try-Cmd 'tasks' {
        Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.Author -like "*$env:USERNAME*" -or $_.Principal.UserId -like "*$env:USERNAME*" } | ForEach-Object {
            $tasks += [pscustomobject]@{ Path = $_.TaskPath; Name = $_.TaskName; State = "$($_.State)"; Author = $_.Author; Action = (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' | ') }
        }
    }
    Save-Csv $tasks 'scheduled-tasks.csv'
    if ($tasks.Count -gt 0) { Try-Cmd 'task xml' { foreach ($t in $tasks) { $x = Export-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop; $safe = ($t.Name -replace '[\\/:*?"<>|]', '_'); Set-Content -LiteralPath (Join-Path $Destination "inventory\task-$safe.xml") -Value $x -Encoding Unicode } } }
    Write-MigLog "Startup items: $($startup.Count); user scheduled tasks: $($tasks.Count)"

    # --- credential manager targets (names only - the secrets cannot be exported) ---
    $cred = Try-Cmd 'cmdkey' { & cmdkey.exe /list 2>$null | Where-Object { $_ -match 'Target:' } | ForEach-Object { $_.Trim() -replace '^Target:\s*', '' } }
    Save-Text @($cred) 'credential-targets.txt'
    Write-MigLog "Credential Manager entries (names only): $(@($cred).Count)"

    # --- default apps (information only; Windows does not let a script set them) ---
    $defaults = @()
    $ua = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations'
    if (Test-Path $ua) { Get-ChildItem $ua | ForEach-Object { $uc = Join-Path $_.PSPath 'UserChoice'; if (Test-Path $uc) { $defaults += [pscustomobject]@{ Kind = 'protocol'; Name = $_.PSChildName; ProgId = (Get-ItemProperty $uc).ProgId } } } }
    $fe = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
    foreach ($ext in '.pdf', '.txt', '.csv', '.xml', '.json', '.html', '.htm', '.md', '.log', '.zip', '.jpg', '.png', '.mp4', '.sql', '.py', '.ps1', '.ini', '.yaml', '.yml') {
        $uc = Join-Path $fe "$ext\UserChoice"; if (Test-Path $uc) { $defaults += [pscustomobject]@{ Kind = 'extension'; Name = $ext; ProgId = (Get-ItemProperty $uc).ProgId } }
    }
    Save-Csv $defaults 'default-apps.csv'

    # --- browser extensions ---
    $bext = @()
    $bdirs = @(); foreach ($bb in @(@{ N = 'Edge'; B = 'edge' }, @{ N = 'Chrome'; B = 'chrome' })) { foreach ($dd in @(Get-MigBrowserDataDirs $bb.B)) { $bdirs += @{ N = $bb.N; P = $dd.Path } } }
    foreach ($b in $bdirs) {
        if (-not (Test-Path -LiteralPath $b.P)) { continue }
        Get-ChildItem -LiteralPath $b.P -Directory | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object {
            $prof = $_
            foreach ($pf in 'Secure Preferences', 'Preferences') {
                $f = Join-Path $prof.FullName $pf
                if (-not (Test-Path -LiteralPath $f)) { continue }
                try {
                    $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
                    $settings = Get-Prop (Get-Prop $j 'extensions') 'settings'
                    if ($settings) {
                        foreach ($p in $settings.PSObject.Properties) {
                            $m = Get-Prop $p.Value 'manifest'
                            if (-not $m) { continue }
                            $name = "$(Get-Prop $m 'name' '')"
                            if ((Get-Prop $p.Value 'location' 0) -in 5, 10) { continue }   # component extensions
                            if ($name -like '__MSG_*' -or -not $name) {
                                # localised name: read _locales/<default_locale>/messages.json inside the extension folder
                                $resolved = $null
                                try {
                                    $extDir = Get-ChildItem -LiteralPath (Join-Path $prof.FullName "Extensions\$($p.Name)") -Directory -ErrorAction Stop | Sort-Object Name -Descending | Select-Object -First 1
                                    if ($extDir) {
                                        $key = ($name -replace '^__MSG_', '' -replace '__$', '')
                                        $loc = "$(Get-Prop $m 'default_locale' 'en')"
                                        foreach ($cand in @($loc, 'en', 'en_US', 'en_GB')) {
                                            $mf = Join-Path $extDir.FullName "_locales\$cand\messages.json"
                                            if (Test-Path -LiteralPath $mf) { $msgs = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json; $entry = $msgs.PSObject.Properties | Where-Object { $_.Name -ieq $key } | Select-Object -First 1; if ($entry) { $resolved = "$($entry.Value.message)"; break } }
                                        }
                                    }
                                } catch { }
                                $name = $(if ($resolved) { $resolved } else { $p.Name })
                            }
                            $storeUrl = $(if ($b.N -eq 'Edge') { "https://microsoftedge.microsoft.com/addons/detail/$($p.Name)" } else { "https://chromewebstore.google.com/detail/$($p.Name)" })
                            $bext += [pscustomobject]@{ Browser = $b.N; Profile = $prof.Name; Id = $p.Name; Name = $name; Version = "$(Get-Prop $m 'version' '')"; Enabled = ((Get-Prop $p.Value 'state' 1) -eq 1); FromPolicy = ((Get-Prop $p.Value 'location' 0) -eq 9); StoreUrl = $storeUrl }
                        }
                    }
                } catch { }
            }
        }
    }
    $ffRoot = "$env:APPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path -LiteralPath $ffRoot) {
        Get-ChildItem -LiteralPath $ffRoot -Directory | ForEach-Object {
            $f = Join-Path $_.FullName 'extensions.json'
            if (Test-Path -LiteralPath $f) { try { $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($a in $j.addons) { if ($a.type -eq 'extension' -and $a.location -eq 'app-profile') { $bext += [pscustomobject]@{ Browser = 'Firefox'; Profile = $_.Name; Id = $a.id; Name = $a.defaultLocale.name; Version = $a.version; Enabled = $a.active; FromPolicy = $false; StoreUrl = "https://addons.mozilla.org/firefox/search/?q=$([uri]::EscapeDataString("$($a.defaultLocale.name)"))" } } } } catch { } }
        }
    }
    $bext = @($bext | Sort-Object Browser, Profile, Id -Unique)
    Save-Csv $bext 'browser-extensions.csv'
    # a readable list with install links, for reinstalling by hand if a copied profile is not accepted
    $bl = New-Object System.Collections.Generic.List[string]
    $bl.Add("# Browser extensions on $env:COMPUTERNAME ($(Get-Date -Format 'yyyy-MM-dd'))"); $bl.Add('')
    $bl.Add('The browser profiles in this backup carry the extensions already. Use this list if a browser does not accept the copied profile, or to re-enable ones it shows as disabled. Click the link, then **Get** / **Add**. Extensions marked *policy* are installed by the company and come back on their own.'); $bl.Add('')
    foreach ($grp in ($bext | Group-Object Browser, Profile)) {
        $first = $grp.Group[0]
        $bl.Add("## $($first.Browser) - profile '$($first.Profile)' ($($grp.Count))"); $bl.Add('')
        $bl.Add('| Extension | Version | State | Install |'); $bl.Add('|---|---|---|---|')
        foreach ($x in ($grp.Group | Sort-Object Name)) { $bl.Add(('| {0} | {1} | {2}{3} | [open store page]({4}) |' -f $x.Name, $x.Version, $(if ($x.Enabled) { 'enabled' } else { 'disabled' }), $(if ($x.FromPolicy) { ', policy' } else { '' }), $x.StoreUrl)) }
        $bl.Add('')
    }
    if ($bext.Count -eq 0) { $bl.Add('No extensions found in Edge, Chrome or Firefox profiles.') }
    Save-Text $bl.ToArray() 'browser-extensions.md'
    Write-MigLog "Browser extensions: $($bext.Count) (list with install links: inventory\browser-extensions.md)"

    # --- VS Code / Cursor extensions ---
    $vsx = @()
    foreach ($pair in @(@{ Cmd = 'code'; Dir = "$env:USERPROFILE\.vscode\extensions" }, @{ Cmd = 'code-insiders'; Dir = "$env:USERPROFILE\.vscode-insiders\extensions" }, @{ Cmd = 'cursor'; Dir = "$env:USERPROFILE\.cursor\extensions" })) {
        $list = $null
        if (Get-Command $pair.Cmd -ErrorAction SilentlyContinue) { $list = Try-Cmd $pair.Cmd { & $pair.Cmd --list-extensions 2>$null } }
        if (-not $list -and (Test-Path -LiteralPath (Join-Path $pair.Dir 'extensions.json'))) {
            $list = Try-Cmd 'extensions.json' { (Get-Content -LiteralPath (Join-Path $pair.Dir 'extensions.json') -Raw | ConvertFrom-Json) | ForEach-Object { $_.identifier.id } }
        }
        if ($list) { $vsx += ($list | Where-Object { $_ } | ForEach-Object { "$($pair.Cmd) $_" }) }
    }
    Save-Text $vsx 'vscode-extensions.txt'
    # readable list with versions and marketplace links (for reinstalling by hand when the Marketplace is reachable but the restore is not)
    $vl = New-Object System.Collections.Generic.List[string]
    $vl.Add("# VS Code extensions on $env:COMPUTERNAME ($(Get-Date -Format 'yyyy-MM-dd'))"); $vl.Add('')
    $vl.Add('The restore reinstalls these automatically when the editor is installed and its command is on PATH. If that is blocked, click a link and press Install, or take the whole extensions folder (entry dev-vscode-extensions-folder).'); $vl.Add('')
    foreach ($pair in @(@{ Cmd = 'code'; Title = 'Visual Studio Code'; Dir = "$env:USERPROFILE\.vscode\extensions"; Store = 'https://marketplace.visualstudio.com/items?itemName=' }, @{ Cmd = 'code-insiders'; Title = 'VS Code Insiders'; Dir = "$env:USERPROFILE\.vscode-insiders\extensions"; Store = 'https://marketplace.visualstudio.com/items?itemName=' }, @{ Cmd = 'cursor'; Title = 'Cursor'; Dir = "$env:USERPROFILE\.cursor\extensions"; Store = 'https://open-vsx.org/extension/' })) {
        $rows = @()
        $mf = Join-Path $pair.Dir 'extensions.json'
        if (Test-Path -LiteralPath $mf) { try { foreach ($x in (Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json)) { $rows += [pscustomobject]@{ Id = "$($x.identifier.id)"; Version = "$($x.version)"; Source = "$(Get-Prop (Get-Prop $x 'metadata') 'source' '')" } } } catch { } }
        if ($rows.Count -eq 0) { $ids = @($vsx | Where-Object { $_ -like "$($pair.Cmd) *" } | ForEach-Object { ($_ -split '\s+')[1] }); foreach ($id in $ids) { $rows += [pscustomobject]@{ Id = $id; Version = ''; Source = '' } } }
        if ($rows.Count -eq 0) { continue }
        $vl.Add("## $($pair.Title) ($($rows.Count))"); $vl.Add(''); $vl.Add('| Extension | Version | Install |'); $vl.Add('|---|---|---|')
        foreach ($r in ($rows | Sort-Object Id -Unique)) { $link = $(if ($pair.Store -like '*open-vsx*') { $pair.Store + ($r.Id -replace '\.', '/') } else { $pair.Store + $r.Id }); $vl.Add(('| {0} | {1} | [open]({2}) |' -f $r.Id, $r.Version, $link)) }
        $vl.Add('')
    }
    if ($vl.Count -le 3) { $vl.Add('No VS Code-family editor found.') }
    Save-Text $vl.ToArray() 'vscode-extensions.md'
    Write-MigLog "VS Code-family extensions: $($vsx.Count) (list with Marketplace links: inventory\vscode-extensions.md)"

    # --- PowerShell modules installed for the user ---
    $psm = Try-Cmd 'PS modules' { Get-Module -ListAvailable | Where-Object { $_.ModuleBase -like "$env:USERPROFILE*" -or $_.ModuleBase -like "$([Environment]::GetFolderPath('MyDocuments'))*" } | Select-Object Name, Version, ModuleBase | Sort-Object Name -Unique }
    Save-Csv $psm 'ps-modules.csv'

    # --- Office details ---
    $office = [ordered]@{ installed = (Test-Path 'HKCU:\Software\Microsoft\Office\16.0'); accounts = @(); comAddins = @(); excelAddins = @(); outlookDataFiles = @() }
    $profRoot = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles'
    if (Test-Path $profRoot) {
        Get-ChildItem $profRoot | ForEach-Object {
            $acctKey = Join-Path $_.PSPath '9375CFF0413111d3B88A00104B2A6676'
            if (Test-Path $acctKey) { Get-ChildItem $acctKey | ForEach-Object { $p = Get-ItemProperty $_.PSPath; $n = Get-Prop $p 'Account Name'; if ($n) { $office.accounts += "$n" } } }
        }
        $office.accounts = @($office.accounts | Sort-Object -Unique)
    }
    foreach ($app in 'Excel', 'Word', 'PowerPoint', 'Outlook', 'Access', 'Project', 'Visio') {
        foreach ($root in "HKCU:\Software\Microsoft\Office\$app\Addins", "HKLM:\Software\Microsoft\Office\$app\Addins", "HKLM:\Software\WOW6432Node\Microsoft\Office\$app\Addins") {
            if (Test-Path $root) { Get-ChildItem $root | ForEach-Object { $p = Get-ItemProperty $_.PSPath; $office.comAddins += [ordered]@{ app = $app; id = $_.PSChildName; name = "$(Get-Prop $p 'FriendlyName' '')"; loadBehavior = (Get-Prop $p 'LoadBehavior' ''); scope = $(if ($root -like 'HKCU*') { 'user' } else { 'machine' }) } } }
        }
    }
    $xo = 'HKCU:\Software\Microsoft\Office\16.0\Excel\Options'
    if (Test-Path $xo) { $it = Get-Item $xo; foreach ($n in $it.GetValueNames()) { if ($n -like 'OPEN*') { $office.excelAddins += "$($it.GetValue($n))" } } }
    foreach ($d in "$env:LOCALAPPDATA\Microsoft\Outlook", "$([Environment]::GetFolderPath('MyDocuments'))\Outlook Files") {
        if (Test-Path -LiteralPath $d) { Get-ChildItem -LiteralPath $d -Include *.pst, *.ost -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $office.outlookDataFiles += [ordered]@{ path = $_.FullName; sizeMB = [math]::Round($_.Length / 1MB, 1) } } }
    }
    Save-Json $office 'office.json'
    Write-MigLog "Office: accounts $($office.accounts.Count), COM add-ins $($office.comAddins.Count), Outlook data files $($office.outlookDataFiles.Count)"

    # --- tool versions and global packages (what to reinstall) ---
    $tv = New-Object System.Collections.Generic.List[string]
    foreach ($c in @(@('git', '--version'), @('python', '--version'), @('py', '--version'), @('node', '--version'), @('npm', '--version'), @('java', '-version'), @('dotnet', '--version'), @('pwsh', '--version'), @('docker', '--version'), @('kubectl', 'version', '--client', '--short'), @('terraform', '--version'), @('az', '--version'), @('aws', '--version'), @('gh', '--version'), @('code', '--version'), @('mvn', '--version'), @('gradle', '--version'), @('go', 'version'), @('rustc', '--version'), @('ruby', '--version'), @('php', '--version'), @('R', '--version'), @('conda', '--version'))) {
        $cmdInfo = Get-Command $c[0] -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmdInfo) { $o = Try-Cmd $c[0] { (& $cmdInfo.Source $c[1..($c.Count - 1)] 2>&1 | Select-Object -First 1) }; $tv.Add("$($c[0]): $o   [$($cmdInfo.Source)]") }
    }
    $tv.Add(''); $tv.Add('--- npm -g ---'); if (Get-Command npm -ErrorAction SilentlyContinue) { Try-Cmd 'npm -g' { & npm ls -g --depth=0 2>$null | ForEach-Object { $tv.Add($_) } } }
    $tv.Add(''); $tv.Add('--- dotnet tools ---'); if (Get-Command dotnet -ErrorAction SilentlyContinue) { Try-Cmd 'dotnet tool' { & dotnet tool list -g 2>$null | ForEach-Object { $tv.Add($_) } } }
    $tv.Add(''); $tv.Add('--- pip --user ---'); if (Get-Command pip -ErrorAction SilentlyContinue) { Try-Cmd 'pip' { & pip list --user --format=freeze 2>$null | ForEach-Object { $tv.Add($_) } } }
    $tv.Add(''); $tv.Add('--- WSL ---'); if (Get-Command wsl -ErrorAction SilentlyContinue) { Try-Cmd 'wsl' { (& wsl.exe -l -v 2>$null) -replace "`0", '' | ForEach-Object { $tv.Add($_) } } }
    Save-Text $tv.ToArray() 'tool-versions.txt'
    Save-Json (Get-MigDevTools) 'dev-tools.json'

    # --- user-level certificates (names only) ---
    $certs = Try-Cmd 'certs' { Get-ChildItem Cert:\CurrentUser\My | Select-Object Subject, Issuer, NotAfter, Thumbprint, HasPrivateKey }
    Save-Csv $certs 'user-certificates.csv'
    if ($certs) { Write-MigLog "Personal certificates: $(@($certs).Count) (cannot be exported without the private key export right - re-enroll)" }
}

# =====================================================================================
# 2. DISCOVERY - what lives in the profile that the catalog does not cover
# =====================================================================================
if (-not $SkipDiscovery) {
    Write-MigLog 'Phase 2: discovery of profile folders' 'STEP'
    $coveredPrefixes = @()
    foreach ($e in $cat.entries) { foreach ($p in @(Get-Prop $e 'paths' @())) { $coveredPrefixes += [pscustomobject]@{ Id = $e.id; Path = (Expand-MigPath $p).TrimEnd('\').ToLower() } } }
    $noisePatterns = '*-updater', '*-nodejs', 'npm-cache', 'pip', 'go-build', 'ms-playwright', 'SquirrelTemp', 'IconCache.db', '.cache', 'node-gyp', 'CEF', 'Downloaded Installations', 'Publishers', 'speech', 'setup', 'ToastNotificationManagerCompat', '*.agreement', 'PUTTY.RND', '.pkg-cache', '*.tmp.*', '*.backup', 'Package Cache', 'D3DSCache', 'NVIDIA', 'AMD', 'AMD_Common', 'Intel', 'Lenovo', 'Dell', 'HP', 'Comms', 'ElevatedDiagnostics', 'Temp', 'CrashDumps', 'ConnectedDevicesPlatform', 'PeerDistRepub', 'PlaceholderTileLogoFolder', 'Packages', 'Microsoft', 'MicrosoftEdge', 'Google', 'Mozilla', 'Adobe', 'Apple Computer', 'Identities', 'Macromedia', 'Sun', 'Oracle', 'Roaming', 'LocalLow', 'Local', 'ntuser.*', 'NTUSER.*'
    $noise = 'Microsoft\Windows\INetCache', 'Microsoft\Windows\Explorer', 'Microsoft\Windows\WebCache', 'Packages', 'Temp', 'D3DSCache', 'CrashDumps', 'ConnectedDevicesPlatform', 'Comms', 'PeerDistRepub', 'PlaceholderTileLogoFolder', 'Microsoft\Windows\History', 'Microsoft\Windows\Caches', 'Microsoft\Windows\Notifications', 'Microsoft\Windows\SchCache', 'Microsoft\Windows\Themes'
    foreach ($rootPair in @(@{ N = 'appdata-roaming'; P = $env:APPDATA }, @{ N = 'appdata-local'; P = $env:LOCALAPPDATA }, @{ N = 'appdata-locallow'; P = (Join-Path $env:USERPROFILE 'AppData\LocalLow') }, @{ N = 'profile-root'; P = $env:USERPROFILE })) {
        if (-not (Test-Path -LiteralPath $rootPair.P)) { continue }
        $rows = @()
        $items = Get-ChildItem -LiteralPath $rootPair.P -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'AppData' -and $_.Name -ne 'Application Data' -and $_.Attributes -notmatch 'ReparsePoint' }
        if ($rootPair.N -eq 'profile-root') { $items = $items | Where-Object { $_.Name -like '.*' -or ($_.PSIsContainer -and $_.Name -notin 'Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music', 'Favorites', 'Links', 'Contacts', 'Searches', 'Saved Games', '3D Objects', 'OneDrive') -or ($_.Name -like 'OneDrive*' -and $false) } }
        foreach ($it in $items) {
            $full = $it.FullName.ToLower()
            $cover = @($coveredPrefixes | Where-Object { $full -eq $_.Path -or $full.StartsWith($_.Path + '\') -or $_.Path.StartsWith($full + '\') } | ForEach-Object { $_.Id } | Sort-Object -Unique)
            $isNoise = $false; foreach ($nz in $noisePatterns) { if ($it.Name -like $nz) { $isNoise = $true; break } }
            if ($it.PSIsContainer) { $st = Get-MigDirStats $it.FullName; $files = $st.Files; $bytes = $st.Bytes } else { $files = 1; $bytes = $it.Length }
            $rows += [pscustomobject]@{ Name = $it.Name; Path = $it.FullName; SizeMB = [math]::Round($bytes / 1MB, 1); Files = $files; LastWrite = $it.LastWriteTime.ToString('yyyy-MM-dd'); CoveredBy = ($cover -join ','); Note = $(if ($cover.Count -gt 0) { '' } elseif ($isNoise) { 'cache/system/vendor' } elseif ($bytes -eq 0) { 'empty' } elseif ($bytes -gt 2GB) { 'NOT COVERED - large, likely content/SDK/VMs - copy by hand if needed' } else { 'NOT COVERED - review' }) }
        }
        $rows | Sort-Object { $_.Note -like 'NOT COVERED*' }, SizeMB -Descending | Export-Csv -LiteralPath (Join-Path $Destination "discovery\$($rootPair.N).csv") -NoTypeInformation -Encoding UTF8
        $unc = @($rows | Where-Object { $_.Note -like 'NOT COVERED*' -and $_.SizeMB -ge 0.1 })
        Write-MigLog "$($rootPair.N): $($rows.Count) folders, $($unc.Count) not covered and non-trivial (see discovery\$($rootPair.N).csv)"
    }
}

# =====================================================================================
# 3. PACKAGES - catalog entries
# =====================================================================================
$entries = Select-MigEntries -Catalog $cat -Include $Include -Exclude $Exclude
if ($IncludeSecrets -and -not $SecretsPassword) {
    $SecretsPassword = Read-Host -AsSecureString 'Password to encrypt the secrets bundle (empty = store secrets UNENCRYPTED in OneDrive)'
    if ($SecretsPassword.Length -eq 0) { $SecretsPassword = $null }
}
$manifest.secretsEncrypted = [bool]$SecretsPassword

function Export-Entry {
    param($Entry)
    $id = $Entry.id
    $isSecret = [bool](Get-Prop $Entry 'secret' $false)
    $kind = Get-Prop $Entry 'kind' 'files'
    $sdir = Join-Path $stage $id
    New-Item -ItemType Directory -Force -Path $sdir | Out-Null
    $items = @(); $totalBytes = 0; $totalFiles = 0; $large = @(); $failed = @(); $longSkipped = @(); $bigDirs = @()
    $dynamic = "$(Get-Prop $Entry 'dynamic' '')"
    if ($kind -eq 'files') {
        $i = 0
        $tokens = @(Get-MigEntryPaths $Entry)   # catalog paths plus what the entry's dynamic rule finds (absolute; the importer rewrites the profile part if needed)
        foreach ($tok in $tokens) {
            $i++
            $src = Expand-MigPath $tok
            if (-not (Test-Path -LiteralPath $src)) { continue }
            if ($dynamic -eq 'browser-dirs' -and $tok -notmatch '^%') { Write-MigLog "${id}: profile folder outside the default location, taken too: $src" }
            $dst = Join-Path $sdir $i
            $isDir = (Get-Item -LiteralPath $src -Force).PSIsContainer
            if ($isDir) {
                # paths over 260 characters: fine when tar.exe is there (it zips them); otherwise leave them out and report them
                $xd = @(Get-Prop $Entry 'excludeDirs' @())
                if (-not (Test-MigLongPathsSupported)) {
                    $lp = Get-MigLongPathExclusions -Source $src -ExtraLength ($dst.Length - $src.Length)
                    $xd += @($lp.Dirs)
                    if ($lp.Files.Count -gt 0) { $longSkipped += @($lp.Files) }
                }
                $r = Invoke-MigRobocopy -Source $src -Destination $dst -ExcludeDirs $xd -ExcludeFiles @(Get-Prop $Entry 'excludeFiles' @()) -IncludeFiles @(Get-Prop $Entry 'includeFiles' @()) -MaxFileMB $MaxFileMB
                if (-not $r.Ok) { $failed += "$src (robocopy $($r.ExitCode)): $($r.Output)" }
                if ($r.Files -eq 0) { Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue; continue }
                $totalBytes += $r.Bytes; $totalFiles += $r.Files
                if ($MaxFileMB -gt 0) { $large += @(Get-MigLargeFiles -Path $src -MinMB $MaxFileMB) }
            } else {
                $fi = Get-Item -LiteralPath $src -Force
                if ($MaxFileMB -gt 0 -and $fi.Length -gt ($MaxFileMB * 1MB)) { $large += $src; continue }
                New-Item -ItemType Directory -Force -Path $dst | Out-Null
                Copy-Item -LiteralPath $src -Destination (Join-Path $dst $fi.Name) -Force
                $totalBytes += $fi.Length; $totalFiles += 1
            }
            $items += [ordered]@{ index = $i; token = $tok; source = $src; type = $(if ($isDir) { 'dir' } else { 'file' }) }
        }
    } else {
        $i = 0
        $keys = @(Get-Prop $Entry 'keys' @())
        if ($dynamic -eq 'hkcu-vendors') { $keys = @(Get-MigOtherVendorKeys $cat | ForEach-Object { $_.Key }) }
        foreach ($key in $keys) {
            $i++
            $out = Join-Path $sdir ('{0}.reg' -f $i)
            if (Export-MigRegistry -Key $key -OutFile $out -ExcludeKeys @(Get-Prop $Entry 'excludeKeys' @())) {
                $len = (Get-Item -LiteralPath $out).Length
                if ($dynamic -eq 'hkcu-vendors' -and $len -gt 5MB) { Remove-Item -LiteralPath $out -Force; $large += "$key ($([math]::Round($len / 1MB)) MB registry key)"; continue }
                $items += [ordered]@{ index = $i; key = $key; file = ('{0}.reg' -f $i); vendor = $(if ($dynamic -eq 'hkcu-vendors') { Split-Path -Leaf $key } else { '' }) }
                $totalFiles += 1; $totalBytes += $len
            }
        }
    }
    if ($items.Count -eq 0) { Remove-Item -LiteralPath $sdir -Recurse -Force -ErrorAction SilentlyContinue; return $null }
    # which sub-folders make a big package big (helps tuning the excludes)
    if ($totalBytes -gt 100MB) {
        foreach ($sub in (Get-ChildItem -LiteralPath $sdir -Directory -ErrorAction SilentlyContinue)) {
            foreach ($sub2 in (Get-ChildItem -LiteralPath $sub.FullName -Directory -ErrorAction SilentlyContinue)) {
                $st = Get-MigDirStats $sub2.FullName; if ($st.Bytes -gt 20MB) { $bigDirs += ('{0} ({1:N0} MB)' -f $sub2.FullName.Substring($sdir.Length + 1), ($st.Bytes / 1MB)) }
            }
        }
        $bigDirs = @($bigDirs | Sort-Object { [double](($_ -replace '.*\((\S+) MB\)$', '$1') -replace ',', '') } -Descending | Select-Object -First 6)
    }
    $zipDir = $(if ($isSecret) { 'secrets' } else { 'packages' })
    $zip = Join-Path $Destination "$zipDir\$id.zip"
    # the destination may be a share or a OneDrive folder that just went away: wait for it rather than fail
    if (-not (Wait-MigReachable -Path $Destination -Mode write -What 'the backup folder')) { throw "backup folder unreachable: $Destination" }
    Compress-MigDirectory -Source $sdir -Zip $zip
    Remove-MigDirectory $sdir
    $rec = [ordered]@{ id = $id; app = $Entry.app; category = (Get-Prop $Entry 'category' ''); kind = $kind; secret = $isSecret; items = $items; files = $totalFiles; bytes = $totalBytes; zip = "$zipDir\$id.zip"; largeFilesSkipped = @($large | Sort-Object -Unique); longPathsSkipped = @($longSkipped | Sort-Object -Unique); bigFolders = $bigDirs; failures = $failed; needsRestart = (Get-Prop $Entry 'needsRestart' ''); notes = (Get-Prop $Entry 'notes' '') }
    if ($isSecret -and $SecretsPassword) {
        Protect-MigFile -Path $zip -OutFile ($zip + '.enc') -Password $SecretsPassword
        Remove-Item -LiteralPath $zip -Force
        $rec.zip = "$zipDir\$id.zip.enc"; $rec['encrypted'] = $true
    }
    return $rec
}

if (-not $SkipPackages) {
    Write-MigLog "Phase 3: packaging $($entries.Count) catalog entries (per-file cap $MaxFileMB MB)" 'STEP'
    $n = 0
    foreach ($e in $entries) {
        $n++
        $isSecret = [bool](Get-Prop $e 'secret' $false)
        if ($isSecret -and -not $IncludeSecrets) { $manifest.skipped += [ordered]@{ id = $e.id; reason = 'secret (use -IncludeSecrets)' }; continue }
        Write-Progress -Activity 'Packaging' -Status "$($e.id) ($n/$($entries.Count))" -PercentComplete (100 * $n / [math]::Max(1, $entries.Count))
        try {
            $rec = Export-Entry $e
            if ($null -eq $rec) { $manifest.skipped += [ordered]@{ id = $e.id; reason = 'not present on this machine' }; continue }
            if ($isSecret) { $manifest.secrets += $rec } else { $manifest.entries += $rec }
            $extra = ''
            if ($rec.largeFilesSkipped.Count -gt 0) { $extra += " | $($rec.largeFilesSkipped.Count) file(s) over cap skipped" }
            if ($rec.longPathsSkipped.Count -gt 0) { $extra += " | $($rec.longPathsSkipped.Count) file(s) with too-long paths skipped" }
            if ($rec.bigFolders.Count -gt 0) { $extra += " | biggest: " + ($rec.bigFolders -join ', ') }
            if ($rec.failures.Count -gt 0) { $extra += " | FAILURES: $($rec.failures.Count)" }
            Write-MigLog ("{0,-28} {1,7} files {2,9:N1} MB{3}" -f $e.id, $rec.files, ($rec.bytes / 1MB), $extra) $(if ($rec.failures.Count -gt 0) { 'WARN' } else { 'OK' })
        } catch {
            Write-MigLog "$($e.id) FAILED: $($_.Exception.Message)" 'ERROR'
            $manifest.skipped += [ordered]@{ id = $e.id; reason = "error: $($_.Exception.Message)" }
        }
    }
    Write-Progress -Activity 'Packaging' -Completed
}
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue

# =====================================================================================
# 4. MANIFEST + REPORT
# =====================================================================================
# Re-running into an existing export folder (e.g. -Include <id> after closing an app) merges into the manifest.
$manifestPath = Join-Path $Destination 'manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $prev = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $nowIds = @{}; foreach ($x in @($manifest.entries) + @($manifest.secrets) + @($manifest.skipped)) { $nowIds["$($x.id)"] = $true }
        $keptE = @(); foreach ($x in @($prev.entries)) { if (-not $nowIds.ContainsKey("$($x.id)")) { $keptE += $x } }
        $keptS = @(); foreach ($x in @($prev.secrets)) { if (-not $nowIds.ContainsKey("$($x.id)")) { $keptS += $x } }
        $keptK = @(); foreach ($x in @($prev.skipped)) { if (-not $nowIds.ContainsKey("$($x.id)")) { $keptK += $x } }
        $manifest.entries = $keptE + @($manifest.entries); $manifest.secrets = $keptS + @($manifest.secrets); $manifest.skipped = $keptK + @($manifest.skipped)
        if ($prev.secretsEncrypted -and $keptS.Count -gt 0) { $manifest.secretsEncrypted = $true }
        Write-MigLog "Merged with the existing manifest in this folder ($($keptE.Count) earlier packages kept)."
    } catch { Write-MigLog "Existing manifest.json could not be merged ($($_.Exception.Message)); it is replaced." 'WARN' }
}
$manifest.finishedAt = (Get-Date).ToString('o')
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$r = $report
$r.Add("# PC migration export - $env:COMPUTERNAME ($env:USERDOMAIN\$env:USERNAME)")
$r.Add('')
$r.Add("Created $($started.ToString('yyyy-MM-dd HH:mm')) with PC Migration kit **$kitVersion**, took $([int]((Get-Date) - $started).TotalMinutes) min. Folder: ``$Destination``")
$r.Add('')
$r.Add('## What to do on the NEW machine')
$r.Add('')
$r.Add('1. Sign in, let OneDrive finish syncing (this folder must show the green tick, not the cloud icon).')
$r.Add('2. Run `Compare-Software.cmd` -> `install-list.md` tells you what to install from the company portal. Install those FIRST.')
$r.Add('3. Close Outlook/Office, browsers, VS Code, Notepad++ etc., then run `Import-Profile.cmd` (add `-WhatIf` first to preview).')
$r.Add('4. Sign out and back in. Then work through the manual list below.')
$r.Add('')
$r.Add('## Packaged settings')
$r.Add('')
$r.Add('| id | app | files | MB | notes |')
$r.Add('|---|---|---:|---:|---|')
foreach ($e in ($manifest.entries | Sort-Object category, id)) { $r.Add(('| `{0}` | {1} | {2} | {3:N1} | {4} |' -f $e.id, $e.app, $e.files, ($e.bytes / 1MB), $(if ($e.largeFilesSkipped.Count) { "**$($e.largeFilesSkipped.Count) large file(s) skipped**" } else { '' }))) }
if ($manifest.secrets.Count -gt 0) {
    $r.Add(''); $r.Add("## Secrets bundle ($(if ($manifest.secretsEncrypted) { 'AES-encrypted with your password' } else { '**NOT ENCRYPTED - plain zips in OneDrive**' }))"); $r.Add('')
    foreach ($e in $manifest.secrets) { $r.Add(('- `{0}` - {1} ({2} files)' -f $e.id, $e.app, $e.files)) }
}
$skippedPresent = @($manifest.skipped | Where-Object { $_.reason -ne 'not present on this machine' })
if ($skippedPresent.Count -gt 0) { $r.Add(''); $r.Add('## Skipped'); $r.Add(''); foreach ($s in $skippedPresent) { $r.Add("- ``$($s.id)``: $($s.reason)") } }
$allLarge = @($manifest.entries | ForEach-Object { $_.largeFilesSkipped } | Where-Object { $_ })
if ($allLarge.Count -gt 0) { $r.Add(''); $r.Add("## Files over the $MaxFileMB MB cap (copy by hand into OneDrive, or re-run with -MaxFileMB)"); $r.Add(''); foreach ($f in $allLarge) { $r.Add("- ``$f``") } }
if ($openEditors.Count -gt 0) { $r.Add(''); $r.Add("## Programs that were open during the export: $($openEditors -join ', ')"); $r.Add(''); $r.Add('Unsaved tabs and documents travel only when the program has written them to disk (Notepad and Notepad++ do so while running, VS Code and Office mostly on close or every few minutes). Save your work, close these programs and run the export again for their entries - the re-run merges into this backup.') }
$allLong = @($manifest.entries | ForEach-Object { $_.longPathsSkipped } | Where-Object { $_ })
if ($allLong.Count -gt 0) { $r.Add(''); $r.Add("## $($allLong.Count) file(s) left out because their path is longer than Windows' 260-character limit"); $r.Add(''); $r.Add('Usually caches of editor extensions, never settings. The first few:'); $r.Add(''); foreach ($f in ($allLong | Select-Object -First 10)) { $r.Add("- ``$f``") } }
$allFail = @($manifest.entries | ForEach-Object { $_.failures } | Where-Object { $_ })
if ($allFail.Count -gt 0) { $r.Add(''); $r.Add('## Copy failures (usually a file locked by a running app - close it and re-run with -Include <id>)'); $r.Add(''); foreach ($f in $allFail) { $r.Add("- $f") } }

# manual to-do list, built from what was actually found
$r.Add(''); $r.Add('## Manual steps after import (things no script can carry)'); $r.Add('')
$m = New-Object System.Collections.Generic.List[string]
$m.Add('**Credential Manager**: Windows, Git, RDP, mapped-drive and Office saved passwords are encrypted to the old PC and the list in `inventory\credential-targets.txt` tells you which ones to re-enter.')
$m.Add('**Browsers**: saved passwords/cookies/payment methods do not travel in Edge/Chrome - sign in to the browser with your work account and let sync restore them. If a browser shows extensions as disabled or missing after the restore, `inventory\browser-extensions.md` lists every extension with a store link to reinstall it.')
$m.Add('**Outlook**: the mail profile is recreated by autodiscover on first start. Afterwards re-select the default signature per account, re-attach any PST, re-tick COM add-ins that show as inactive.')
$m.Add('**Default apps**: Windows does not let a script set them. `inventory\default-apps.csv` lists yours; set them in Settings > Apps > Default apps.')
$m.Add('**Certificates**: user certificates (`inventory\user-certificates.csv`) must be re-enrolled; private keys cannot be exported.')
$m.Add('**Network printers / mapped drives**: Import-Profile re-adds them from the inventory; drivers for a network printer come from the print server.')
$m.Add('**Wi-Fi / VPN**: corporate profiles are pushed by Intune/GPO; personal Wi-Fi keys need admin to export - re-type them.')
$m.Add('**Taskbar / Start pins**: restored, but a pin to a program that is not installed yet shows broken until the program is installed from the portal.')
if (Test-Path "$env:USERPROFILE\.vscode\extensions") { $m.Add('**VS Code extensions**: Import-Profile reinstalls them when `code` is on PATH; otherwise `inventory\vscode-extensions.txt` is the list.') }
if (Get-Command wsl -ErrorAction SilentlyContinue) { $m.Add('**WSL**: distributions are not copied. `wsl --export <name> <OneDrive>\<name>.tar` on this PC, `wsl --import` on the new one (needs WSL installed there).') }
if (Test-Path "$env:USERPROFILE\.m2\settings.xml") { $m.Add('**Maven**: `~/.m2/settings.xml` is exported in clear and may contain Artifactory credentials - check it.') }
if (Test-Path "$env:USERPROFILE\.ssh") { $m.Add('**SSH keys**: only exported with `-IncludeSecrets`. Alternatively generate a new key on the new PC and register its public half wherever the old one was used.') }
foreach ($e in $manifest.entries) { if ($e.notes -and ($e.needsRestart -or $e.notes -match 'CLOSED|re-|by hand|must')) { $m.Add(('**{0}** (`{1}`): {2}' -f $e.app, $e.id, $e.notes)) } }
foreach ($line in $m) { $r.Add("- $line") }
$r.Add(''); $r.Add('## Inventory files'); $r.Add('')
Get-ChildItem (Join-Path $Destination 'inventory') -File | ForEach-Object { $r.Add("- ``inventory\$($_.Name)`` ($([math]::Round($_.Length / 1KB)) KB)") }
$r.Add(''); $r.Add('`discovery\*.csv` list every profile folder with its size and whether a catalog entry covers it. Rows marked **NOT COVERED - review** are settings of apps this kit does not know - add an entry to `catalog.json` or copy them by hand.')
Set-Content -LiteralPath (Join-Path $Destination 'report.md') -Value $r -Encoding UTF8

$totalBytesAll = 0; foreach ($e in @($manifest.entries) + @($manifest.secrets)) { $totalBytesAll += [int64]$e.bytes }
$totalMB = [math]::Round($totalBytesAll / 1MB, 1)
Write-MigLog "Done. $($manifest.entries.Count) packages + $($manifest.secrets.Count) secret packages, $totalMB MB; $(@($manifest.skipped).Count) catalog entries not present/skipped." 'STEP'
Write-MigLog "Report: $(Join-Path $Destination 'report.md')" 'OK'
Write-MigLog 'Wait for OneDrive to finish syncing this folder before using it on the new machine.' 'WARN'
