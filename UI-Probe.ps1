<#
  UI-Probe.ps1 - read-only questions the PC Migration app asks the engine, answered as JSON on stdout.
  The app (PCMigration.exe) never looks at AppData or the registry itself: everything that defines "what a
  setting is" stays in MigrationCommon.psm1 and catalog.json, and this script is the one door to it.

    -Mode export-scan                     catalog entries present on this PC and the custom folders remembered from the last backup
    -Mode discovered                      AppData folders of programs the catalog does not know (slow: it measures them)
    -Mode sizes -Ids a,b,c                one JSON line per entry as it is measured: {"id":"...","mb":12.3}
    -Mode backups                         backups under the backup root (manifest summary, placeholder count, checklist state)
    -Mode import-scan -Source <backup>    one row per package in the backup: ready / waiting for a program / restored earlier
    -Mode dirstats -Path <folder>         size of a folder the user wants to add
    -Mode environment                     user, admin, network, OneDrive, backup root, kit version
#>
param(
    [Parameter(Mandatory)][ValidateSet('export-scan', 'discovered', 'sizes', 'backups', 'import-scan', 'dirstats', 'environment')][string]$Mode,
    [string]$Source,
    [string]$Path,
    [string[]]$Ids
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'MigrationCommon.psm1') -Force
$catalog = Get-MigCatalog (Join-Path $scriptDir 'catalog.json')
function Out-Json { param($Object, [int]$Depth = 8) Write-Output ($Object | ConvertTo-Json -Depth $Depth -Compress) }
function Get-Exports {
    $root = Get-MigRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return @() }
    $out = New-Object System.Collections.ArrayList
    foreach ($d in (Get-ChildItem -LiteralPath $root -Directory | Sort-Object LastWriteTime -Descending)) {
        $m = Join-Path $d.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $m)) { continue }
        try { $j = Get-Content -LiteralPath $m -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        [void]$out.Add([pscustomobject]@{ Dir = $d; Manifest = $j })
    }
    return $out.ToArray()
}

switch ($Mode) {
    'environment' {
        $net = Test-MigNetwork
        $root = Get-MigRoot
        Out-Json ([ordered]@{
            computer = $env:COMPUTERNAME; user = "$env:USERDOMAIN\$env:USERNAME"; admin = (Test-MigAdmin); kitVersion = (Get-MigVersion)
            oneDrive = (Get-MigOneDriveRoot); backupRoot = $root; backupRootExists = [bool]($root -and (Test-Path -LiteralPath $root)); rootFromEnv = [bool]$env:PCMIG_ROOT
            networkAvailable = [bool]$net.Available; networkProfiles = @($net.Profiles); oneDriveRunning = [bool]$net.OneDriveRunning
            os = "$([Environment]::OSVersion.Version)"
        })
    }
    'dirstats' {
        $st = Get-MigDirStats -Path $Path -ExcludeDirs @('node_modules', '.git', '.venv', '__pycache__')
        Out-Json ([ordered]@{ path = $Path; mb = [math]::Round($st.Bytes / 1MB, 1); files = $st.Files })
    }
    'backups' {
        $list = New-Object System.Collections.ArrayList
        foreach ($ex in (Get-Exports)) {
            $j = $ex.Manifest; $p = $ex.Dir.FullName
            $ph = 0; try { $ph = @(Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue | Where-Object { ([int]$_.Attributes -band 0x400000) -ne 0 }).Count } catch { }
            $bytes = [int64]0; foreach ($e in @($j.entries) + @($j.secrets)) { $bytes += [int64](Get-Prop $e 'bytes' 0) }
            $st = Get-MigInstallState $p
            $rs = Join-Path $p "restore-state-$env:COMPUTERNAME.json"; $restored = 0; $deferred = 0
            if (Test-Path -LiteralPath $rs) { try { $sj = Get-Content -LiteralPath $rs -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($x in $sj.entries.PSObject.Properties) { if ("$($x.Value.status)" -eq 'restored') { $restored++ } elseif ("$($x.Value.status)" -eq 'deferred') { $deferred++ } } } catch { } }
            [void]$list.Add([ordered]@{
                path = $p; name = $ex.Dir.Name; computer = "$($j.computer)"; user = "$($j.user)"; createdAt = "$($j.createdAt)"
                packages = @($j.entries).Count; secrets = @($j.secrets).Count; secretsEncrypted = [bool](Get-Prop $j 'secretsEncrypted' $false)
                bytes = $bytes; kitVersion = "$(Get-Prop $j 'kitVersion' '')"; newerThanThisKit = ((Compare-MigVersion "$(Get-Prop $j 'kitVersion' '0')" (Get-MigVersion)) -gt 0)
                placeholders = $ph; madeHere = ("$($j.computer)" -eq $env:COMPUTERNAME)
                checklistInstalled = @($st.Values | Where-Object { $_.status -eq 'installed' }).Count; checklistSkipped = @($st.Values | Where-Object { $_.status -eq 'skipped' }).Count
                checklistExists = (Test-Path -LiteralPath (Join-Path $p "install-state-$env:COMPUTERNAME.json")); restored = $restored; deferred = $deferred
                hasReport = (Test-Path -LiteralPath (Join-Path $p 'report.md')); hasExtensions = (Test-Path -LiteralPath (Join-Path $p 'inventory\browser-extensions.md'))
            })
        }
        Out-Json ([ordered]@{ root = (Get-MigRoot); backups = $list.ToArray() })
    }
    'export-scan' {
        $rows = New-Object System.Collections.ArrayList
        foreach ($e in $catalog.entries) {
            $found = $false; $badge = ''
            switch ("$(Get-Prop $e 'dynamic' '')") {
                'hkcu-vendors' { $vk = @(Get-MigOtherVendorKeys $catalog); $found = ($vk.Count -gt 0); if ($found) { $badge = "$($vk.Count) program(s): " + (($vk | Select-Object -First 12 | ForEach-Object { $_.Vendor }) -join ', ') + $(if ($vk.Count -gt 12) { ', ...' } else { '' }) } }
                'bruno-collections' { $bp = @(Get-MigBrunoCollectionPaths); $found = ($bp.Count -gt 0); if ($found) { $badge = "$($bp.Count) collection folder(s): " + (($bp | Select-Object -First 4) -join '; ') } }
                'putty-keyfiles' { $kf = @(Get-MigPuttyKeyFiles); $found = ($kf.Count -gt 0); if ($found) { $badge = "$($kf.Count) key file(s): " + (($kf | Select-Object -First 3) -join '; ') + $(if ($kf.Count -gt 3) { '; ...' } else { '' }) } }
                'browser-dirs' {
                    foreach ($p in @(Get-MigEntryPaths $e)) { if (Test-Path -LiteralPath (Expand-MigPath $p)) { $found = $true; break } }
                    if ($found) { $bd = @(@(Get-MigBrowserDataDirs "$(Get-Prop $e 'browser' '')") | Where-Object { $_.Via -ne 'default' }); if ($bd.Count) { $badge = 'Also found outside the default location, taken too: ' + (($bd | ForEach-Object { "$($_.Path) ($($_.Via))" }) -join '; ') } }
                }
                default {
                    if ((Get-Prop $e 'kind' 'files') -eq 'files') { foreach ($p in @(Get-Prop $e 'paths' @())) { if (Test-Path -LiteralPath (Expand-MigPath $p)) { $found = $true; break } } }
                    else { foreach ($k in @(Get-Prop $e 'keys' @())) { if (Test-MigRegKey $k) { $found = $true; break } } }
                }
            }
            if (-not $found) { continue }
            [void]$rows.Add([ordered]@{
                id = "$($e.id)"; app = "$($e.app)"; category = "$(Get-Prop $e 'category' 'tools')"; kind = "$(Get-Prop $e 'kind' 'files')"
                summary = "$(Get-Prop $e 'summary' '')"; notes = "$(Get-Prop $e 'notes' '')"; secret = [bool](Get-Prop $e 'secret' $false)
                defaultOff = [bool](Get-Prop $e 'defaultOff' $false); badge = $badge; mb = $(if ((Get-Prop $e 'kind' 'files') -eq 'registry') { 0.01 } else { $null })
            })
        }
        # folders the user added last time on this computer, remembered in that backup's extra-entries.json
        $custom = New-Object System.Collections.ArrayList
        $prev = @(Get-Exports | Where-Object { "$($_.Manifest.computer)" -eq $env:COMPUTERNAME } | Select-Object -First 1)
        if ($prev.Count -gt 0) {
            $pf = Join-Path $prev[0].Dir.FullName 'extra-entries.json'
            if (Test-Path -LiteralPath $pf) { try { foreach ($c in @((Get-Content -LiteralPath $pf -Raw -Encoding UTF8 | ConvertFrom-Json).entries | Where-Object { "$($_.category)" -eq 'custom' })) { [void]$custom.Add($c) } } catch { } }
        }
        Out-Json ([ordered]@{ entries = $rows.ToArray(); custom = $custom.ToArray() }) 10
    }
    'discovered' {
        $disc = New-Object System.Collections.ArrayList
        foreach ($d in @(Get-MigDiscoveredAppData $catalog)) { [void]$disc.Add($d) }
        Out-Json ([ordered]@{ discovered = $disc.ToArray() }) 10
    }
    'sizes' {
        $want = @{}; foreach ($i in @($Ids)) { foreach ($x in ("$i" -split ',')) { if ($x.Trim()) { $want[$x.Trim()] = $true } } }
        foreach ($e in $catalog.entries) {
            if (-not $want.ContainsKey("$($e.id)")) { continue }
            $bytes = [int64]0
            foreach ($p in @(Get-MigEntryPaths $e)) {
                $x = Expand-MigPath $p; if (-not (Test-Path -LiteralPath $x)) { continue }
                $it = Get-Item -LiteralPath $x -Force
                if ($it.PSIsContainer) { $bytes += (Get-MigDirStats -Path $x -ExcludeDirs @(Get-Prop $e 'excludeDirs' @()) -ExcludeFiles @(Get-Prop $e 'excludeFiles' @()) -IncludeFiles @(Get-Prop $e 'includeFiles' @()) -MaxFileMB 500).Bytes } else { $bytes += $it.Length }
            }
            Write-Output (('{{"id":"{0}","mb":{1}}}' -f $e.id, [math]::Round($bytes / 1MB, 2)))
        }
    }
    'import-scan' {
        $mf = Get-Content -LiteralPath (Join-Path $Source 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $catalog = Merge-MigExtraEntries -Catalog $catalog -Path (Join-Path $Source 'extra-entries.json')
        $byId = @{}; foreach ($e in $catalog.entries) { $byId["$($e.id)"] = $e }
        $prev = @{}; $sp = Join-Path $Source "restore-state-$env:COMPUTERNAME.json"
        if (Test-Path -LiteralPath $sp) { try { $sj = Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $sj.entries.PSObject.Properties) { $prev[$p.Name] = $p.Value } } catch { } }
        $ck = Get-MigInstallState $Source
        $ckItems = @(); $cif = Join-Path $Source 'install-items.json'
        if (Test-Path -LiteralPath $cif) { try { $ckItems = @((Get-Content -LiteralPath $cif -Raw -Encoding UTF8 | ConvertFrom-Json).items | Where-Object { "$($_.kind)" -in 'program', 'store', 'portable', 'tool' }) } catch { } }
        $skippedNames = @($ckItems | Where-Object { $ck["$($_.key)"] -and $ck["$($_.key)"].status -eq 'skipped' } | ForEach-Object { "$($_.name)" })
        $manualNames = @($ckItems | Where-Object { $ck["$($_.key)"] -and $ck["$($_.key)"].status -eq 'installed' -and $ck["$($_.key)"].by -eq 'user' } | ForEach-Object { "$($_.name)" })
        $matchProg = { param($entry, $names) foreach ($c in @(Get-Prop $entry 'appCheck' @())) { if ("$c" -like 'uninstall:*') { $re = "$c".Substring(10); foreach ($n in $names) { if ($n -match $re) { return $n } } } }; $an = "$(Get-Prop $entry 'appName' '')"; if ($an) { foreach ($n in $names) { if ($n -match [regex]::Escape($an) -or $an -match [regex]::Escape($n)) { return $n } } }; return $null }
        $rows = New-Object System.Collections.ArrayList
        foreach ($pk in @(@($mf.entries) | ForEach-Object { @{ P = $_; S = $false } }) + @(@($mf.secrets) | ForEach-Object { @{ P = $_; S = $true } })) {
            $p = $pk.P; $id = "$($p.id)"; $e = $byId[$id]
            $inst = $(if ($e) { Test-MigAppInstalled $e } else { $null }); $pv = $prev[$id]
            $skippedBy = $(if ($e) { & $matchProg $e $skippedNames } else { $null }); $manualBy = $(if ($e -and $inst -eq $false) { & $matchProg $e $manualNames } else { $null })
            $state = 'ready'; $checked = -not (Get-Prop $e 'defaultOff' $false); $enabled = $true; $badge = ''; $kind = ''; $force = $false
            if ($skippedBy -and -not ($pv -and "$($pv.status)" -eq 'restored')) { $checked = $false; $badge = "You skipped '$skippedBy' on the install list - left out. Tick it to restore these settings anyway."; $kind = 'info'; $state = 'skipped' }
            elseif ($manualBy) { $force = $true; $checked = $true; $badge = "You marked '$manualBy' as installed - restored even though it was not detected."; $kind = 'success' }
            elseif ($inst -eq $false) { $enabled = $false; $checked = $false; $badge = "Waiting for $(Get-MigAppName $e) to be installed. Install it (or mark it installed on the install list), then run this app again."; $kind = 'warning'; $state = 'waiting' }
            elseif ($pv -and "$($pv.status)" -eq 'restored') { $checked = $false; $badge = "Restored earlier ($(([datetime]$pv.at).ToString('dd MMM HH:mm'))). Tick to restore again."; $kind = 'success'; $state = 'done' }
            elseif ($pv -and "$($pv.status)" -eq 'deferred') { $checked = $true; $badge = "$(Get-MigAppName $e) is installed now - ready to restore."; $kind = 'success' }
            elseif ($e -and "$(Get-Prop $e 'dynamic' '')" -eq 'hkcu-vendors') {
                $vend = @($p.items | ForEach-Object { "$($_.vendor)" } | Where-Object { $_ })
                $ready = @($vend | Where-Object { Test-MigVendorInstalled $_ }); $wait = @($vend | Where-Object { $ready -notcontains $_ })
                $checked = ($ready.Count -gt 0); $badge = "Ready now: $(if ($ready.Count) { $ready -join ', ' } else { 'none' }). Waiting for a program: $(if ($wait.Count) { $wait -join ', ' } else { 'none' }) - picked up on a later run."; $kind = 'info'
            }
            if ($pk.S) { $checked = $false }
            [void]$rows.Add([ordered]@{
                id = $id; app = "$($p.app)"; category = $(if ($pk.S) { 'secrets' } else { "$($p.category)" }); secret = [bool]$pk.S
                summary = $(if ($e) { "$(Get-Prop $e 'summary' '')" } else { '' }); notes = $(if ($e) { "$(Get-Prop $e 'notes' '')" } else { '' })
                mb = [math]::Round([double](Get-Prop $p 'bytes' 0) / 1MB, 2); state = $state; checked = [bool]$checked; enabled = [bool]$enabled; badge = $badge; badgeKind = $kind; force = [bool]$force
                needsClose = $(if ($e) { "$(Get-Prop $e 'needsClose' '')" } else { '' })
            })
        }
        Out-Json ([ordered]@{ computer = "$($mf.computer)"; user = "$($mf.user)"; createdAt = "$($mf.createdAt)"; kitVersion = "$(Get-Prop $mf 'kitVersion' '')"; secretsEncrypted = [bool](Get-Prop $mf 'secretsEncrypted' $false); rows = $rows.ToArray() }) 6
    }
}
