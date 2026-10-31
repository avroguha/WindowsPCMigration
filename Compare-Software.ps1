<#
.SYNOPSIS
  Compares the OLD machine's software inventory (from Export-Profile) with what is installed HERE and writes
  install-list.md / install-list.csv: what to get from the company portal, what came with the machine, what to ignore.

.PARAMETER Source   Export folder (contains inventory\software.csv). Default: newest under OneDrive\PCMigration.
.PARAMETER Output   Folder for install-list.*; default = the export folder.

.EXAMPLE
  .\Compare-Software.ps1
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Output
)
$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'MigrationCommon.psm1') -Force

if (-not $Source) {
    $root = Get-MigRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { throw "No backup folder found (OneDrive\PCMigration or PCMIG_ROOT). Pass -Source." }
    $cand = Get-ChildItem -LiteralPath $root -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'inventory\software.csv') } | Sort-Object LastWriteTime -Descending
    if (-not $cand) { throw "No export with inventory\software.csv under $root" }
    $Source = $cand[0].FullName
}
if (-not $Output) { $Output = $Source }
$old = @(Import-Csv -LiteralPath (Join-Path $Source 'inventory\software.csv'))
$oldStoreFile = Join-Path $Source 'inventory\store-apps.csv'
$oldStore = if ((Test-Path -LiteralPath $oldStoreFile) -and (Get-Item -LiteralPath $oldStoreFile).Length -gt 0) { @(Import-Csv -LiteralPath $oldStoreFile) } else { @() }
$oldPortableFile = Join-Path $Source 'inventory\portable-apps.csv'
$oldPortable = if ((Test-Path -LiteralPath $oldPortableFile) -and (Get-Item -LiteralPath $oldPortableFile).Length -gt 0) { @(Import-Csv -LiteralPath $oldPortableFile) } else { @() }
$sysFile = Join-Path $Source 'inventory\system.json'
$oldSys = if (Test-Path -LiteralPath $sysFile) { Get-Content -LiteralPath $sysFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

Write-Host "PC Migration kit $(Get-MigVersion)"
Write-Host "Old machine: $($old.Count) programs, $($oldStore.Count) store apps (from $Source)"
$new = Get-InstalledSoftware
$newStore = Get-StoreApps
Write-Host "This machine: $($new.Count) programs, $($newStore.Count) store apps"

# normalise names so "7-Zip 23.01 (x64)" matches "7-Zip 24.08 (x64 edition)"
function Normalize-Name {
    param([string]$n)
    $s = $n.ToLower()
    $s = $s -replace '\(.*?\)', ' '                                     # parenthetical
    $s = $s -replace '\b(x64|x86|64-bit|32-bit|amd64|arm64|win64|win32|edition)\b', ' '
    $s = $s -replace '\bv?\d+(\.\d+)+([a-z0-9\-]*)\b', ' '               # versions
    $s = $s -replace '\b(20\d\d|19\d\d)\b', ' '                          # years
    $s = $s -replace '\b(version|release|update|build|kb\d+)\b', ' '
    $s = $s -replace '[^a-z0-9+#. ]', ' '
    $s = $s -replace '\s+', ' '
    return $s.Trim()
}

# classification: what is noise, what comes with any corporate build, what is OEM
$noiseName = '^(Update for|Security Update for|Hotfix for|Service Pack)', 'Microsoft Visual C\+\+ .* (Redistributable|Runtime|Minimum Runtime|Additional Runtime)', 'Microsoft \.NET( Core)? (Runtime|SDK|Host|Framework|AppHost|Targeting|Templates)', 'Windows SDK', 'Windows Software Development Kit', 'Microsoft Edge( WebView2| Update)?$', 'Microsoft OneDrive', 'Microsoft Update Health Tools', 'Microsoft 365|Microsoft Office|Office 16 Click-to-Run', 'Microsoft Teams', 'Microsoft Intune', 'Windows PC Health Check', 'Microsoft ASP\.NET Core', 'vs_|Visual Studio .* (Installer|Tools for|Build Tools)', 'Microsoft Windows Desktop Runtime', 'Microsoft (GameInput|Edge Dev|OneNote)', 'Microsoft Azure Information Protection', 'Microsoft Authentication', 'Microsoft Visual Studio Code \(User\)$'
$oemPublisher = '^(Intel|NVIDIA|Realtek|AMD|Advanced Micro Devices|Dell|HP|HP Inc|Hewlett|Lenovo|Synaptics|Conexant|Qualcomm|Dolby|Waves|ELAN|Alps|Logitech|Microsoft Corporation \(driver\)|Fortemedia|Cirrus|DTS|Sierra Wireless|Killer|Thunderbolt)'
$oemName = '(Driver|Chipset|Graphics|Audio|Bluetooth|Wireless|Wi-?Fi|Touchpad|Firmware|BIOS|Dolby|Thunderbolt|Management Engine|Vantage|Support Assist|SupportAssist|Power Manager|Realtek|Intel\(R\))'
$corpAgent = '(Zscaler|CrowdStrike|Falcon|Tanium|Qualys|Carbon Black|SentinelOne|Cortex XDR|Netskope|BeyondTrust|CyberArk|Microsoft Monitoring Agent|Configuration Manager|SCCM|Nexthink|1E |Ivanti|BigFix|Rapid7|Splunk|Cisco AnyConnect|Cisco Secure Client|GlobalProtect|Pulse Secure|Forcepoint|Symantec|McAfee|Trellix|Digital Guardian|Code42|Okta Verify|Duo|Citrix Workspace|Microsoft Defender|Company Portal|Nudge|Absolute|Lakeside|Aternity|LogMeIn|TeamViewer Host|Bomgar|SecureAuth|Workspace ONE|Jamf)'

$newNorm = @{}; foreach ($n in $new) { $k = Normalize-Name $n.Name; if (-not $newNorm.ContainsKey($k)) { $newNorm[$k] = @() }; $newNorm[$k] += $n }
$newStoreNames = @{}; foreach ($s in $newStore) { $newStoreNames[$s.Name] = $s }

$rows = @()
foreach ($o in $old) {
    $k = Normalize-Name $o.Name
    $match = $null
    if ($newNorm.ContainsKey($k)) { $match = $newNorm[$k] | Select-Object -First 1 }
    if (-not $match) {
        # looser: first two words
        $w = @($k -split ' ' | Where-Object { $_.Length -gt 2 }) ; if ($w.Count -ge 2) { $pfx = "$($w[0]) $($w[1])"; $cand = $newNorm.Keys | Where-Object { $_.StartsWith($pfx) } | Select-Object -First 1; if ($cand) { $match = $newNorm[$cand] | Select-Object -First 1 } }
    }
    $class = ''
    $isNoise = $false; foreach ($re in $noiseName) { if ($o.Name -match $re) { $isNoise = $true; break } }
    if ([int]$o.SystemComponent -eq 1) { $isNoise = $true }
    if ($isNoise) { $class = 'ignore (runtime/update/platform - comes with other installs or Windows)' }
    elseif (($o.Publisher -match $oemPublisher) -or ($o.Name -match $oemName)) { $class = 'OEM/driver - belongs to the old hardware, do not install' }
    elseif ($o.Name -match $corpAgent -or $o.Publisher -match $corpAgent) { $class = 'corporate agent - IT pushes it, do not install yourself' }
    elseif ($o.Scope -like 'User*') { $class = 'per-user install - you installed it without admin; portal or vendor download' }
    else { $class = 'INSTALL from the company portal (or request it)' }
    $status = if ($match) { 'present' } else { 'missing' }
    $rows += [pscustomobject]@{
        Status      = $status
        Action      = $(if ($status -eq 'present') { "already here ($($match.Version))" } else { $class })
        Name        = $o.Name
        Version     = $o.Version
        Publisher   = $o.Publisher
        Scope       = $o.Scope
        InstallDate = $o.InstallDate
        HereVersion = $(if ($match) { "$($match.Version)" } else { '' })
        Priority    = $(if ($status -eq 'present') { 9 } elseif ($class -like 'INSTALL*') { 1 } elseif ($class -like 'per-user*') { 2 } elseif ($class -like 'corporate*') { 5 } elseif ($class -like 'OEM*') { 7 } else { 8 })
    }
}
foreach ($s in $oldStore) {
    if ($newStoreNames.ContainsKey($s.Name)) { continue }
    if ($s.SignatureKind -eq 'System' -or $s.Name -like 'Microsoft.*' -or $s.Name -like 'Windows*' -or $s.Name -like 'MicrosoftWindows*' -or $s.Name -like '*Lenovo*' -or $s.Name -like '*Dell*' -or $s.Name -like '*HP*' -or $s.Name -like '*Intel*' -or $s.Name -like '*Realtek*' -or $s.Name -like '*NVIDIA*' -or $s.Name -like '*AMD*' -or $s.Name -like '*Synaptics*') { continue }
    $rows += [pscustomobject]@{ Status = 'missing'; Action = 'Microsoft Store app - install from the Store / Company Portal'; Name = $s.Name; Version = $s.Version; Publisher = $s.Publisher; Scope = 'Store'; InstallDate = ''; HereVersion = ''; Priority = 3 }
}
foreach ($p in $oldPortable) {
    $here = "$($p.Folder)" -replace [regex]::Escape("$($oldSys.profile)"), $env:USERPROFILE
    if (Test-Path -LiteralPath $here) { $rows += [pscustomobject]@{ Status = 'present'; Action = 'already here (program folder)'; Name = $p.Folder; Version = ''; Publisher = $p.Executables; Scope = 'Portable'; InstallDate = "$($p.SizeMB) MB"; HereVersion = ''; Priority = 9 }; continue }
    $rows += [pscustomobject]@{ Status = 'missing'; Action = 'portable/per-user program folder - re-download or copy the folder as content'; Name = $p.Folder; Version = ''; Publisher = $p.Executables; Scope = 'Portable'; InstallDate = "$($p.SizeMB) MB"; HereVersion = ''; Priority = 4 }
}

$rows = $rows | Sort-Object Priority, Name
$rows | Select-Object Status, Action, Name, Version, Publisher, Scope, InstallDate | Export-Csv -LiteralPath (Join-Path $Output 'install-list.csv') -NoTypeInformation -Encoding UTF8

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Software to install on $env:COMPUTERNAME")
$md.Add('')
$md.Add("Old machine: **$($oldSys.computer)** ($($oldSys.osCaption) build $($oldSys.osBuild)) - $($old.Count) programs. This machine: $($new.Count) programs. Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm').")
$md.Add('')
function Add-Section { param([string]$Title, $Items, [string]$Hint)
    if (-not $Items -or @($Items).Count -eq 0) { return }
    $md.Add("## $Title ($(@($Items).Count))"); $md.Add('')
    if ($Hint) { $md.Add($Hint); $md.Add('') }
    $md.Add('| Name | Version on old PC | Publisher | Installed |'); $md.Add('|---|---|---|---|')
    foreach ($i in $Items) { $md.Add("| $($i.Name) | $($i.Version) | $($i.Publisher) | $($i.InstallDate) |") }
    $md.Add('')
}
Add-Section '1. Install from the company portal' ($rows | Where-Object { $_.Priority -eq 1 }) 'Machine-wide programs that were on the old PC and are not here. Search the portal by name; where a program is not offered, raise a request quoting name + version.'
Add-Section '2. Per-user programs you installed yourself' ($rows | Where-Object { $_.Priority -eq 2 }) 'These were installed without admin (per-user). Reinstall them the same way, or from the portal if offered.'
Add-Section '3. Microsoft Store apps' ($rows | Where-Object { $_.Priority -eq 3 }) ''
Add-Section '4. Portable / per-user program folders' ($rows | Where-Object { $_.Priority -eq 4 }) 'Folders under your profile that hold programs (no installer). Re-download, or copy the folder via OneDrive if licensing allows. The old folder path is in Name, the executables in Publisher.'
Add-Section '5. Corporate agents (do nothing)' ($rows | Where-Object { $_.Priority -eq 5 }) 'IT deploys these; if one is missing after a day, tell the service desk.'
Add-Section '6. Drivers / OEM tools from the old hardware (do not install)' ($rows | Where-Object { $_.Priority -eq 7 }) ''
Add-Section '7. Runtimes, updates, platform pieces (ignore)' ($rows | Where-Object { $_.Priority -eq 8 }) 'These arrive with the programs that need them.'
Add-Section '8. Already installed here' ($rows | Where-Object { $_.Priority -eq 9 }) ''
Set-Content -LiteralPath (Join-Path $Output 'install-list.md') -Value $md -Encoding UTF8
# ---------------- unified install checklist: install-items.json (the wizard's "What to install" page) ----------------
$items = @()
foreach ($r in ($rows | Where-Object { $_.Priority -in 1, 2, 3, 4, 9 })) {
    $kind = switch ($r.Scope) { 'Store' { 'store' } 'Portable' { 'portable' } default { 'program' } }
    $name = $(if ($kind -eq 'portable') { Split-Path -Leaf $r.Name } else { $r.Name })
    $items += [ordered]@{ key = "$kind|$($r.Name)"; kind = $kind; name = $name; detail = "$($r.Publisher)"; oldVersion = "$($r.Version)"; hereVersion = "$(Get-Prop $r 'HereVersion' '')"; link = $(if ($kind -eq 'store') { "ms-windows-store://search/?query=$([uri]::EscapeDataString($name))" } else { '' }); command = ''; installed = ($r.Status -eq 'present'); hint = $(if ($kind -eq 'portable') { "was in $($r.Name)" } elseif ($r.Priority -eq 2) { 'per-user install - no admin needed' } else { 'company portal' }) }
}
$bextOld = Join-Path $Source 'inventory\browser-extensions.csv'
if ((Test-Path -LiteralPath $bextOld) -and (Get-Item -LiteralPath $bextOld).Length -gt 0) {
    $here = @(Get-MigBrowserExtensions); $hereIds = @{}; foreach ($x in $here) { $hereIds["$($x.Browser)|$($x.Id)"] = "$($x.Version)" }
    foreach ($x in (Import-Csv -LiteralPath $bextOld)) {
        if ("$($x.FromPolicy)" -eq 'True') { continue }
        $items += [ordered]@{ key = "browser-ext|$($x.Browser)|$($x.Id)"; kind = 'browser-ext'; name = $x.Name; detail = "$($x.Browser)"; oldVersion = "$($x.Version)"; hereVersion = "$($hereIds["$($x.Browser)|$($x.Id)"])"; link = "$(Get-Prop $x 'StoreUrl' '')"; command = ''; installed = $hereIds.ContainsKey("$($x.Browser)|$($x.Id)"); hint = '' }
    }
}
$devOld = Join-Path $Source 'inventory\dev-tools.json'
if (Test-Path -LiteralPath $devOld) {
    $old = Get-Content -LiteralPath $devOld -Raw -Encoding UTF8 | ConvertFrom-Json
    $now = Get-MigDevTools
    $nowTools = @{}; foreach ($t in @($now.tools)) { $nowTools[$t.name] = $t.version }
    foreach ($t in @($old.tools)) { $items += [ordered]@{ key = "tool|$($t.name)"; kind = 'tool'; name = $t.name; detail = ''; oldVersion = "$($t.version)"; hereVersion = "$($nowTools[$t.name])"; link = ''; command = ''; installed = $nowTools.ContainsKey($t.name); hint = $(if ($nowTools.ContainsKey($t.name)) { '' } else { 'install from the portal, then re-check' }) } }
    $nowNpm = @{}; foreach ($p in @($now.npmGlobal)) { $nowNpm[$p.name] = "$($p.version)" }
    foreach ($p in @($old.npmGlobal)) { $items += [ordered]@{ key = "npm|$($p.name)"; kind = 'npm'; name = $p.name; detail = ''; oldVersion = "$($p.version)"; hereVersion = "$($nowNpm[$p.name])"; link = "https://www.npmjs.com/package/$($p.name)"; command = "npm install -g $($p.name)@$($p.version)"; installed = $nowNpm.ContainsKey($p.name); hint = 'needs Node.js first' } }
    $nowPip = @{}; foreach ($p in @($now.pipUser)) { $nowPip[$p.name.ToLower()] = "$($p.version)" }
    foreach ($p in @($old.pipUser)) { $items += [ordered]@{ key = "pip|$($p.name)"; kind = 'pip'; name = $p.name; detail = ''; oldVersion = "$($p.version)"; hereVersion = "$($nowPip["$($p.name)".ToLower()])"; link = "https://pypi.org/project/$($p.name)/"; command = "pip install --user $($p.name)==$($p.version)"; installed = $nowPip.ContainsKey("$($p.name)".ToLower()); hint = 'needs Python first' } }
    $nowDn = @{}; foreach ($p in @($now.dotnetTools)) { $nowDn[$p.name.ToLower()] = "$($p.version)" }
    foreach ($p in @($old.dotnetTools)) { $items += [ordered]@{ key = "dotnet-tool|$($p.name)"; kind = 'dotnet-tool'; name = $p.name; detail = ''; oldVersion = "$($p.version)"; hereVersion = "$($nowDn["$($p.name)".ToLower()])"; link = "https://www.nuget.org/packages/$($p.name)"; command = "dotnet tool install -g $($p.name) --version $($p.version)"; installed = $nowDn.ContainsKey("$($p.name)".ToLower()); hint = 'needs the .NET SDK first' } }
    $nowPs = @{}; foreach ($p in @($now.psModules)) { $nowPs[$p.name.ToLower()] = "$($p.version)" }
    foreach ($p in @($old.psModules)) { $items += [ordered]@{ key = "ps-module|$($p.name)"; kind = 'ps-module'; name = $p.name; detail = ''; oldVersion = "$($p.version)"; hereVersion = "$($nowPs["$($p.name)".ToLower()])"; link = "https://www.powershellgallery.com/packages/$($p.name)"; command = "Install-Module -Name '$($p.name)' -RequiredVersion '$($p.version)' -Scope CurrentUser -Force"; installed = $nowPs.ContainsKey("$($p.name)".ToLower()); hint = '' } }
    $nowVsx = @{}; foreach ($x in @($now.vscodeExtensions)) { $nowVsx["$($x.editor)|$($x.id)".ToLower()] = "$($x.version)" }
    foreach ($x in @($old.vscodeExtensions)) { $store = $(if ($x.editor -eq 'cursor') { 'https://open-vsx.org/extension/' + ($x.id -replace '\.', '/') } else { "https://marketplace.visualstudio.com/items?itemName=$($x.id)" }); $items += [ordered]@{ key = "vscode-ext|$($x.editor)|$($x.id)"; kind = 'vscode-ext'; name = $x.id; detail = "$($x.editor)"; oldVersion = "$($x.version)"; hereVersion = "$($nowVsx["$($x.editor)|$($x.id)".ToLower()])"; link = $store; command = "$($x.editor) --install-extension $($x.id) --force"; installed = $nowVsx.ContainsKey("$($x.editor)|$($x.id)".ToLower()); hint = 'the restore installs these automatically when the editor is on PATH' } }
}
@{ computer = $env:COMPUTERNAME; generatedAt = (Get-Date).ToString('o'); items = $items } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Output 'install-items.json') -Encoding UTF8
$n1 = @($rows | Where-Object Priority -eq 1).Count; $n2 = @($rows | Where-Object Priority -eq 2).Count; $n9 = @($rows | Where-Object Priority -eq 9).Count
Write-Host "install-items.json: $($items.Count) items ($(@($items | Where-Object { $_.installed }).Count) already present here)"
Write-Host "install-list.md written to $Output : $n1 to install from the portal, $n2 per-user reinstalls, $n9 already present."
