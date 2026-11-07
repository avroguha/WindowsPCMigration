# MigrationCommon.psm1 - shared helpers for Export-Profile / Import-Profile / Compare-Software.
# Everything here works as a standard (non-admin) user on Windows PowerShell 5.1.

$script:LogFile = $null

# Kit version: the VERSION file beside this module (the exe and the zip carry it; builds are named after it).
function Get-MigVersion {
    $f = Join-Path $PSScriptRoot 'VERSION'
    if (Test-Path -LiteralPath $f) { return (Get-Content -LiteralPath $f -Raw).Trim() }
    return 'dev'
}
# Compare two dotted versions: -1 / 0 / 1 (unknown strings compare as 0).
function Compare-MigVersion {
    param([string]$A, [string]$B)
    try { $va = [version]($A -replace '[^0-9.].*$', ''); $vb = [version]($B -replace '[^0-9.].*$', ''); return $va.CompareTo($vb) } catch { return 0 }
}

function Initialize-MigLog {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir -WhatIf:$false | Out-Null }
    $script:LogFile = $Path
}

function Write-MigLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','STEP','WAIT')][string]$Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -WhatIf:$false }
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'STEP'  { Write-Host ''; Write-Host $line -ForegroundColor Cyan }
        'WAIT'  { Write-Host $line -ForegroundColor DarkYellow }
        default { Write-Host $line }
    }
}

# Safe property read for PSCustomObjects coming from JSON (missing property -> default).
function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Test-MigAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Path tokens: standard %VAR% plus a few that depend on folder redirection (OneDrive Known Folder Move).
function Expand-MigPath {
    param([Parameter(Mandatory)][string]$Path)
    $map = @{
        '%DOCUMENTS%' = [Environment]::GetFolderPath('MyDocuments')
        '%DESKTOP%'   = [Environment]::GetFolderPath('Desktop')
        '%PICTURES%'  = [Environment]::GetFolderPath('MyPictures')
    }
    $out = $Path
    foreach ($k in $map.Keys) { $out = $out.Replace($k, $map[$k]) }
    return [Environment]::ExpandEnvironmentVariables($out)
}

function Get-MigOneDriveRoot {
    foreach ($v in @($env:OneDriveCommercial, $env:OneDrive, $env:OneDriveConsumer)) {
        if ($v -and (Test-Path -LiteralPath $v)) { return $v }
    }
    return $null
}

# Where backups live: PCMIG_ROOT (a share or any folder) beats OneDrive\PCMigration.
function Get-MigRoot {
    if ($env:PCMIG_ROOT) { return $env:PCMIG_ROOT }
    $od = Get-MigOneDriveRoot
    if ($od) { return (Join-Path $od 'PCMigration') }
    return $null
}

# Is the program that owns a catalog entry installed here? $true / $false, or $null when the entry has no appCheck.
$script:InstalledCache = $null
function Test-MigAppInstalled {
    param($Entry)
    $checks = @(Get-Prop $Entry 'appCheck' @())
    if ($checks.Count -eq 0) { return $null }
    foreach ($c in $checks) {
        $c = "$c"
        try {
            if ($c -like 'uninstall:*') {
                if ($null -eq $script:InstalledCache) { $script:InstalledCache = @(Get-InstalledSoftware) }
                $re = $c.Substring(10)
                if (@($script:InstalledCache | Where-Object { $_.Name -match $re }).Count -gt 0) { return $true }
            } elseif ($c -like 'cmd:*') {
                if (Get-Command $c.Substring(4) -CommandType Application -ErrorAction SilentlyContinue) { return $true }
            } elseif ($c -like 'appx:*') {
                if (Get-AppxPackage -Name $c.Substring(5) -ErrorAction SilentlyContinue) { return $true }
            } elseif ($c -like 'HKCU\*' -or $c -like 'HKLM\*') {
                if (Test-Path -LiteralPath ('Registry::' + $c)) { return $true }
            } else {
                if (Test-Path -LiteralPath (Expand-MigPath $c)) { return $true }
            }
        } catch { }
    }
    return $false
}
function Get-MigAppName { param($Entry) return (Get-Prop $Entry 'appName' (Get-Prop $Entry 'app' '')) }

function Get-MigCatalog {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Catalog not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $cat = $raw | ConvertFrom-Json
    $ids = @{}
    foreach ($e in $cat.entries) {
        if ($ids.ContainsKey($e.id)) { throw "Duplicate catalog id: $($e.id)" }
        $ids[$e.id] = $true
    }
    return $cat
}

# Select catalog entries by id or category, honouring -Include / -Exclude.
function Select-MigEntries {
    param($Catalog, [string[]]$Include, [string[]]$Exclude)
    # powershell -File passes "a,b,c" as one string: split on commas
    if ($Include) { $Include = @($Include | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($Exclude) { $Exclude = @($Exclude | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $out = @()
    foreach ($e in $Catalog.entries) {
        $cat = Get-Prop $e 'category' ''
        $keep = $true
        if ($Include -and $Include.Count -gt 0) {
            $keep = ($Include -contains $e.id) -or ($Include -contains $cat)
        }
        if ($Exclude -and (($Exclude -contains $e.id) -or ($Exclude -contains $cat))) { $keep = $false }
        if ($keep) { $out += $e }
    }
    return $out
}

# ---------- robocopy ----------

# Copies a tree with excludes and a per-file size cap. Returns a summary object.
function Invoke-MigRobocopy {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeFiles = @(),
        [string[]]$IncludeFiles = @(),
        [int]$MaxFileMB = 0,
        [switch]$Overwrite
    )
    $rcArgs = @($Source, $Destination)
    if ($IncludeFiles.Count -gt 0) { $rcArgs += $IncludeFiles }
    $rcArgs += @('/E', '/COPY:DAT', '/DCOPY:T', '/XJ', '/R:1', '/W:1', '/NP', '/NFL', '/NDL', '/NJH', '/BYTES')
    if ($Overwrite) { $rcArgs += '/IS'; $rcArgs += '/IT' }
    if ($MaxFileMB -gt 0) { $rcArgs += ('/MAX:{0}' -f ([int64]$MaxFileMB * 1MB)) }
    if ($ExcludeDirs.Count -gt 0)  { $rcArgs += '/XD'; $rcArgs += $ExcludeDirs }
    if ($ExcludeFiles.Count -gt 0) { $rcArgs += '/XF'; $rcArgs += $ExcludeFiles }
    $out = & robocopy.exe @rcArgs 2>&1
    $code = $LASTEXITCODE
    $summary = [ordered]@{ ExitCode = $code; Files = 0; Bytes = 0; Failed = 0; Skipped = 0; Ok = ($code -lt 8) }
    foreach ($line in $out) {
        if ($line -match '^\s*Files\s*:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') { $summary.Files = [int]$matches[2]; $summary.Skipped = [int]$matches[3]; $summary.Failed = [int]$matches[5] }
        elseif ($line -match '^\s*Bytes\s*:\s*(\d+)\s+(\d+)') { $summary.Bytes = [int64]$matches[2] }
    }
    if ($code -ge 8) {
        $errs = @()
        for ($i = 0; $i -lt $out.Count; $i++) {
            if ("$($out[$i])" -match '\sERROR\s+\d+\s') {
                $e = "$($out[$i])".Trim() -replace '^\S+\s+\S+\s+', ''
                if ($i + 1 -lt $out.Count) { $e += ' - ' + "$($out[$i + 1])".Trim() }
                $errs += $e
            }
        }
        $summary['Output'] = (($errs | Select-Object -First 8) -join ' | ')
    }
    return [pscustomobject]$summary
}

# Fast size/count of a directory using robocopy's list-only mode (much faster than Get-ChildItem -Recurse).
function Get-MigDirStats {
    param([Parameter(Mandatory)][string]$Path, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @(), [string[]]$IncludeFiles = @(), [int]$MaxFileMB = 0)
    $r = [ordered]@{ Files = 0; Bytes = 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]$r }
    $nul = Join-Path $env:TEMP ('migstat-' + [guid]::NewGuid().ToString('N'))
    $rcArgs = @($Path, $nul)
    if ($IncludeFiles.Count -gt 0) { $rcArgs += $IncludeFiles }
    $rcArgs += @('/L', '/E', '/XJ', '/BYTES', '/NFL', '/NDL', '/NJH', '/NP', '/R:0', '/W:0')
    if ($MaxFileMB -gt 0) { $rcArgs += ('/MAX:{0}' -f ([int64]$MaxFileMB * 1MB)) }
    if ($ExcludeDirs.Count -gt 0)  { $rcArgs += '/XD'; $rcArgs += $ExcludeDirs }
    if ($ExcludeFiles.Count -gt 0) { $rcArgs += '/XF'; $rcArgs += $ExcludeFiles }
    $out = & robocopy.exe @rcArgs 2>&1
    foreach ($line in $out) {
        if ($line -match '^\s*Files\s*:\s*(\d+)') { $r.Files = [int]$matches[1] }
        elseif ($line -match '^\s*Bytes\s*:\s*(\d+)') { $r.Bytes = [int64]$matches[1] }
    }
    return [pscustomobject]$r
}

# Lists files at or above a size (used to report what the /MAX cap left behind).
function Get-MigLargeFiles {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$MinMB)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $nul = Join-Path $env:TEMP ('miglarge-' + [guid]::NewGuid().ToString('N'))
    $out = & robocopy.exe $Path $nul /L /E /XJ /NDL /NJH /NJS /NP /NC /NS /FP /R:0 /W:0 ('/MIN:{0}' -f ([int64]$MinMB * 1MB)) 2>&1
    return @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
}

# Files whose path would exceed MAX_PATH once staged: robocopy copies them, but every zip API fails on them.
# Returns the directories to pass to /XD (full paths) and the files that will be skipped because of it.
function Get-MigLongPathExclusions {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][int]$ExtraLength, [int]$Limit = 245)
    $files = @(); $dirs = @{}
    if (-not (Test-Path -LiteralPath $Source)) { return [pscustomobject]@{ Dirs = @(); Files = @() } }
    $nul = Join-Path $env:TEMP ('miglong-' + [guid]::NewGuid().ToString('N'))
    $out = & robocopy.exe $Source $nul /L /E /XJ /NDL /NJH /NJS /NP /NC /NS /FP /R:0 /W:0 2>&1
    foreach ($line in $out) {
        $f = "$line".Trim()
        if (-not $f -or -not $f.StartsWith($Source, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (($f.Length + $ExtraLength) -gt $Limit) {
            $files += $f
            # exclude the shallowest directory under Source whose own staged length already exceeds the limit,
            # otherwise the file's parent
            $parent = Split-Path -Parent $f
            $cand = $parent
            while ($true) { $up = Split-Path -Parent $cand; if (-not $up -or $up.Length -le $Source.Length -or ($up.Length + $ExtraLength) -le $Limit) { break }; $cand = $up }
            $dirs[$cand] = $true
        }
    }
    return [pscustomobject]@{ Dirs = @($dirs.Keys); Files = $files }
}

# ---------- network / reachability ----------

function Test-MigNetwork {
    $avail = [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    $names = @()
    try { $names = @(Get-NetConnectionProfile -ErrorAction Stop | ForEach-Object { "$($_.Name) ($($_.InterfaceAlias), $($_.IPv4Connectivity))" }) } catch { }
    $od = Get-Process -Name OneDrive -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Available = $avail; Profiles = $names; OneDriveRunning = [bool]$od }
}

# Is the backup location usable right now? write = can create a file there; read = can open the given file.
function Test-MigReachable {
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('read', 'write')][string]$Mode = 'write')
    try {
        if ($Mode -eq 'write') {
            if (-not (Test-Path -LiteralPath $Path)) { return $false }
            $probe = Join-Path $Path ('.pcmig-probe-' + [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText($probe, 'probe'); Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return $true
        } else {
            $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite'); $b = New-Object byte[] 1; [void]$fs.Read($b, 0, 1); $fs.Dispose(); return $true
        }
    } catch { return $false }
}

# Blocks until the location is reachable again, logging PAUSE/RESUME so the wizard can show it. $false on timeout.
function Wait-MigReachable {
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('read', 'write')][string]$Mode = 'write', [int]$TimeoutMinutes = 60, [string]$What = 'the backup location')
    if (Test-MigReachable -Path $Path -Mode $Mode) { return $true }
    $net = Test-MigNetwork
    Write-MigLog ("PAUSE: cannot reach {0} ({1}). Network {2}. Waiting up to {3} min and resuming automatically..." -f $What, $Path, $(if ($net.Available) { 'is up' } else { 'is DOWN' }), $TimeoutMinutes) 'WAIT'
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes); $n = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10; $n++
        if (Test-MigReachable -Path $Path -Mode $Mode) { Write-MigLog "RESUME: $What is reachable again." 'OK'; return $true }
        if ($n % 30 -eq 0) { Write-MigLog ("PAUSE: still waiting for {0} ({1} min)..." -f $What, ($n / 6)) 'WAIT' }
    }
    Write-MigLog "PAUSE timed out after $TimeoutMinutes min; $What is still unreachable." 'ERROR'
    return $false
}

# ---------- zip ----------

# Zips are made and opened with the bsdtar that ships in Windows 10 1803+ / 11 (C:\Windows\System32\tar.exe): it handles
# paths longer than 260 characters on every machine, whereas .NET's ZipFile only does when the LongPathsEnabled policy is
# on (it is off on most company PCs). Without tar.exe the .NET route is used and long paths are left out (see
# Get-MigLongPathExclusions). The zip layout is the same either way: entries relative to the staged folder.
$script:TarExe = $null
function Get-MigTar {
    if ($null -eq $script:TarExe) { $c = Get-Command tar.exe -CommandType Application -ErrorAction SilentlyContinue; $script:TarExe = $(if ($c) { $c.Source } else { '' }) }
    return $script:TarExe
}
function Test-MigLongPathsSupported { return [bool](Get-MigTar) }

function Compress-MigDirectory {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Zip)
    if (Test-Path -LiteralPath $Zip) { Remove-Item -LiteralPath $Zip -Force }
    $dir = Split-Path -Parent $Zip
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tar = Get-MigTar
    if ($tar) {
        $out = & $tar -a -cf $Zip -C $Source . 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Zip)) { return }
        Write-MigLog "tar.exe could not write $Zip (exit $LASTEXITCODE): $(($out | Select-Object -First 3) -join ' | ') - falling back to .NET" 'WARN'
        Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
    }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::CreateFromDirectory($Source, $Zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    } catch {
        Write-MigLog "ZipFile unavailable ($($_.Exception.Message)); falling back to Compress-Archive (2 GB limit)" 'WARN'
        Compress-Archive -Path (Join-Path $Source '*') -DestinationPath $Zip -CompressionLevel Optimal -Force
    }
}

function Expand-MigArchive {
    param([Parameter(Mandatory)][string]$Zip, [Parameter(Mandatory)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-MigDirectory $Destination }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $tar = Get-MigTar
    if ($tar) {
        $out = & $tar -xf $Zip -C $Destination 2>&1
        if ($LASTEXITCODE -eq 0) { return }
        Write-MigLog "tar.exe could not open $Zip (exit $LASTEXITCODE): $(($out | Select-Object -First 3) -join ' | ') - falling back to .NET" 'WARN'
    }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Destination)
    } catch {
        Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force
    }
}

# Cooperative pause: the app drops a request file next to the backup; the scripts look for it before every item,
# finish the item in hand, log a PAUSED line naming what is left, and end normally (manifest, state and report are
# written as usual). The app turns that line into resume-<computer>.json so the rest can run later - after a reboot too.
function Get-MigPauseFile { param([Parameter(Mandatory)][string]$BackupFolder) return (Join-Path $BackupFolder ".pause-request-$env:COMPUTERNAME") }
function Test-MigPauseRequested {
    param([Parameter(Mandatory)][string]$BackupFolder)
    $f = Get-MigPauseFile $BackupFolder
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; return $true }
    return $false
}

# Removes a staging folder that may hold paths longer than 260 characters (Remove-Item cannot): robocopy mirrors an
# empty folder over it, which it can do at any depth, then the empty shell goes.
function Remove-MigDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $Path -or $Path.Length -lt 8 -or -not (Test-Path -LiteralPath $Path)) { return }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $empty = Join-Path $env:TEMP ('migempty-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    & robocopy.exe $empty $Path /MIR /NJH /NJS /NFL /NDL /NP /R:0 /W:0 | Out-Null
    Remove-Item -LiteralPath $Path, $empty -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- encryption for the secrets bundle (AES-256-CBC, PBKDF2 200k) ----------

function ConvertTo-MigPlainText {
    param([Parameter(Mandatory)][SecureString]$Secure)
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Protect-MigFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OutFile, [Parameter(Mandatory)][SecureString]$Password)
    $pw = ConvertTo-MigPlainText $Password
    $salt = New-Object byte[] 16; $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($salt); $rng.GetBytes($iv)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw, $salt, 200000)
    $aes = [System.Security.Cryptography.Aes]::Create(); $aes.KeySize = 256; $aes.Key = $kdf.GetBytes(32); $aes.IV = $iv
    $fsOut = [System.IO.File]::Create($OutFile)
    try {
        $magic = [Text.Encoding]::ASCII.GetBytes('PCMIG1')
        $fsOut.Write($magic, 0, $magic.Length); $fsOut.Write($salt, 0, 16); $fsOut.Write($iv, 0, 16)
        $cs = New-Object System.Security.Cryptography.CryptoStream($fsOut, $aes.CreateEncryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write)
        $fsIn = [System.IO.File]::OpenRead($Path)
        try { $fsIn.CopyTo($cs) } finally { $fsIn.Dispose() }
        $cs.FlushFinalBlock(); $cs.Dispose()
    } finally { $fsOut.Dispose(); $aes.Dispose() }
}

function Unprotect-MigFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OutFile, [Parameter(Mandatory)][SecureString]$Password)
    $pw = ConvertTo-MigPlainText $Password
    $fsIn = [System.IO.File]::OpenRead($Path)
    try {
        $magic = New-Object byte[] 6; [void]$fsIn.Read($magic, 0, 6)
        if ([Text.Encoding]::ASCII.GetString($magic) -ne 'PCMIG1') { throw "Not a PCMigration encrypted file: $Path" }
        $salt = New-Object byte[] 16; $iv = New-Object byte[] 16
        [void]$fsIn.Read($salt, 0, 16); [void]$fsIn.Read($iv, 0, 16)
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw, $salt, 200000)
        $aes = [System.Security.Cryptography.Aes]::Create(); $aes.KeySize = 256; $aes.Key = $kdf.GetBytes(32); $aes.IV = $iv
        $cs = New-Object System.Security.Cryptography.CryptoStream($fsIn, $aes.CreateDecryptor(), [System.Security.Cryptography.CryptoStreamMode]::Read)
        $fsOut = [System.IO.File]::Create($OutFile)
        try { $cs.CopyTo($fsOut) } finally { $fsOut.Dispose() }
        $cs.Dispose(); $aes.Dispose()
    } finally { $fsIn.Dispose() }
}

# ---------- registry ----------

function Test-MigRegKey {
    param([Parameter(Mandatory)][string]$Key)
    return (Test-Path -LiteralPath ("Registry::" + $Key))
}

# reg export + optional removal of whole sections (subtrees) from the .reg text.
function Export-MigRegistry {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$OutFile, [string[]]$ExcludeKeys = @())
    if (-not (Test-MigRegKey $Key)) { return $false }
    $tmp = Join-Path $env:TEMP ('migreg-' + [guid]::NewGuid().ToString('N') + '.reg')
    $null = & reg.exe export $Key $tmp /y 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp)) { return $false }
    if ($ExcludeKeys.Count -eq 0) { Move-Item -LiteralPath $tmp -Destination $OutFile -Force; return $true }
    $text = [System.IO.File]::ReadAllText($tmp, [Text.Encoding]::Unicode)
    Remove-Item -LiteralPath $tmp -Force
    # split into header + sections; each section starts with a line "[HKEY_...]"
    $parts = [regex]::Split($text, '(?m)^(?=\[HKEY_)')
    $keep = New-Object System.Text.StringBuilder
    [void]$keep.Append($parts[0])
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $sec = $parts[$i]
        $hdr = ($sec -split "`r?`n", 2)[0].Trim().TrimStart('[').TrimEnd(']')
        $drop = $false
        foreach ($x in $ExcludeKeys) {
            $xf = $x -replace '^HKCU\\', 'HKEY_CURRENT_USER\'
            if ($hdr -eq $xf -or $hdr.StartsWith($xf + '\', [StringComparison]::OrdinalIgnoreCase)) { $drop = $true; break }
        }
        if (-not $drop) { [void]$keep.Append($sec) }
    }
    [System.IO.File]::WriteAllText($OutFile, $keep.ToString(), [Text.Encoding]::Unicode)
    return $true
}

# Rewrites the old profile path to the new one inside a .reg file (plain string values; REG_EXPAND_SZ /
# REG_BINARY hex blobs are left alone and counted), then reg import.
function Import-MigRegistry {
    param([Parameter(Mandatory)][string]$File, [string]$OldProfile, [string]$NewProfile)
    $src = $File
    $hexHits = 0
    if ($OldProfile -and $NewProfile -and ($OldProfile -ne $NewProfile)) {
        $text = [System.IO.File]::ReadAllText($File, [Text.Encoding]::Unicode)
        $oldEsc = $OldProfile.Replace('\', '\\'); $newEsc = $NewProfile.Replace('\', '\\')
        $text2 = [regex]::Replace($text, [regex]::Escape($oldEsc), $newEsc.Replace('$', '$$'), 'IgnoreCase')
        $oldHex = (([Text.Encoding]::Unicode.GetBytes($OldProfile) | ForEach-Object { $_.ToString('x2') }) -join ',')
        $joined = $text2 -replace '\\\r?\n\s*', ''
        $hexHits = ([regex]::Matches($joined, [regex]::Escape($oldHex), 'IgnoreCase')).Count
        $src = Join-Path $env:TEMP ('migimp-' + [guid]::NewGuid().ToString('N') + '.reg')
        [System.IO.File]::WriteAllText($src, $text2, [Text.Encoding]::Unicode)
    }
    $out = & reg.exe import $src 2>&1
    $code = $LASTEXITCODE
    if ($src -ne $File) { Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ Ok = ($code -eq 0); Output = (($out | ForEach-Object { "$_" }) -join ' '); HexPathsLeft = $hexHits }
}

# Replace the old profile path in text config files under a restored tree (only when usernames differ).
function Update-MigProfilePaths {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$OldProfile, [Parameter(Mandatory)][string]$NewProfile)
    if ($OldProfile -eq $NewProfile) { return 0 }
    $exts = '.json', '.ini', '.xml', '.config', '.txt', '.yml', '.yaml', '.toml', '.properties', '.cfg', '.conf', '.gitconfig', '.npmrc', '.settings', '.rdp', '.reg', '.ps1', '.bat', '.cmd'
    $n = 0
    $old2 = $OldProfile.Replace('\', '\\'); $new2 = $NewProfile.Replace('\', '\\')
    $old3 = $OldProfile.Replace('\', '/'); $new3 = $NewProfile.Replace('\', '/')
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Length -lt 8MB -and ($exts -contains $_.Extension.ToLower() -or $_.Name -like '.*rc' -or $_.Name -like '.git*')
    } | ForEach-Object {
        try {
            $t = [System.IO.File]::ReadAllText($_.FullName)
            if ($t.IndexOf($OldProfile, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $t.IndexOf($old3, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return }
            $t2 = [regex]::Replace($t, [regex]::Escape($old2), $new2.Replace('$', '$$'), 'IgnoreCase')
            $t2 = [regex]::Replace($t2, [regex]::Escape($old3), $new3.Replace('$', '$$'), 'IgnoreCase')
            $t2 = [regex]::Replace($t2, [regex]::Escape($OldProfile), $NewProfile.Replace('$', '$$'), 'IgnoreCase')
            if ($t2 -ne $t) { [System.IO.File]::WriteAllText($_.FullName, $t2); $n++ }
        } catch { }
    }
    return $n
}

# ---------- dynamic entries ----------

# HKCU\Software vendor keys that no catalog entry covers and that are worth carrying.
function Get-MigOtherVendorKeys {
    param($Catalog)
    $deny = @('Microsoft', 'Classes', 'Clients', 'Policies', 'RegisteredApplications', 'Wow6432Node', 'appdatalow', 'SyncEngines', 'IM Providers',
        'AMD', 'ATI', 'NVIDIA Corporation', 'Intel', 'Realtek', 'Lenovo', 'Dell', 'HP', 'Hewlett-Packard', 'Synaptics', 'Canon', 'Epson', 'Logitech', 'Dolby', 'Waves Audio', 'Conexant', 'ELAN',
        'Google', 'Mozilla', 'Opera Software', 'Chromium', 'Chrome for Testing', 'BraveSoftware', 'Vivaldi', 'ArcBrowser', 'Island', 'Netscape', 'Macromedia',
        'Apple Inc.', 'Apple Computer, Inc.', 'Valve', 'Mojang', 'Epic Games', 'Tailscale IPN', 'OpenSSH', 'Wine', 'Cygwin', 'WinRAR SFX', 'BugSplat',
        'Python', 'PythonCore', 'JavaSoft', 'Node.js', 'GoProgrammingLanguage', 'ODBC',
        'Zscaler', 'CrowdStrike', 'Cisco', 'Palo Alto Networks', 'Citrix', 'Tanium', 'Qualys', 'Netskope', 'Symantec', 'McAfee', 'Trellix', 'Okta', 'Duo Security', 'VMware, Inc.', 'Nexthink', 'BeyondTrust', 'CyberArk')
    $covered = @{}
    foreach ($e in $Catalog.entries) {
        foreach ($k in @(Get-Prop $e 'keys' @())) {
            if ("$k" -match '^HKCU\\Software\\([^\\]+)') { $covered[$matches[1].ToLower()] = $true }
        }
    }
    $out = @()
    foreach ($sk in (Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue)) {
        $n = $sk.PSChildName
        if ($deny -contains $n -or $covered.ContainsKey($n.ToLower())) { continue }
        if ($n -match '^\{[0-9A-Fa-f-]+\}$') { continue }
        if ($sk.ValueCount -eq 0 -and $sk.SubKeyCount -eq 0) { continue }
        $out += [pscustomobject]@{ Vendor = $n; Key = "HKCU\Software\$n" }
    }
    return @($out | Sort-Object Vendor)
}

# Does an installed program look like it belongs to this HKCU\Software vendor key?
function Test-MigVendorInstalled {
    param([Parameter(Mandatory)][string]$Vendor)
    if ($null -eq $script:InstalledCache) { $script:InstalledCache = @(Get-InstalledSoftware) }
    $v = $Vendor.Trim()
    $re = [regex]::Escape($v)
    foreach ($s in $script:InstalledCache) {
        if ($s.Name -match $re -or $s.Publisher -match $re) { return $true }
        # "Mobatek" vs "MobaXterm": share a meaningful prefix
        $w = ($s.Name -split '[\s\-_]')[0]
        if ($w.Length -ge 5 -and $v.Length -ge 5 -and ($v.StartsWith($w.Substring(0, 5), 'OrdinalIgnoreCase'))) { return $true }
    }
    foreach ($d in @("$env:ProgramFiles\$v", "${env:ProgramFiles(x86)}\$v", "$env:LOCALAPPDATA\Programs\$v", "$env:LOCALAPPDATA\$v", "$env:APPDATA\$v")) { if (Test-Path -LiteralPath $d) { return $true } }
    return $false
}

# Bruno keeps collections as plain folders wherever the user chose; find them from its config and state files.
function Get-MigBrunoCollectionPaths {
    $cfg = Join-Path $env:APPDATA 'bruno'
    if (-not (Test-Path -LiteralPath $cfg)) { return @() }
    $cands = New-Object System.Collections.Generic.List[string]
    try { $pref = Get-Content -LiteralPath (Join-Path $cfg 'preferences.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json; $dl = "$(Get-Prop (Get-Prop (Get-Prop $pref 'preferences') 'general') 'defaultLocation' '')"; if ($dl) { $cands.Add($dl) } } catch { }
    foreach ($f in (Get-ChildItem -LiteralPath $cfg -Filter *.json -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(Cache|Code Cache|GPUCache|IndexedDB|Local Storage|Session Storage|WebStorage|blob_storage|logs)\\' })) {
        try { $t = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 } catch { continue }
        foreach ($m in [regex]::Matches($t, '[A-Za-z]:(\\\\|/)[^"<>|*?]+')) { $cands.Add(($m.Value -replace '\\\\', '\' -replace '/', '\')) }
    }
    $dirs = @{}
    foreach ($c in $cands) {
        $pth = $c.TrimEnd('\')
        if (-not (Test-Path -LiteralPath $pth -PathType Container)) { continue }
        if (Test-Path -LiteralPath (Join-Path $pth 'bruno.json')) { $dirs[$pth.ToLower()] = $pth; continue }
        # a default location holds collections as sub-folders
        foreach ($sub in (Get-ChildItem -LiteralPath $pth -Directory -ErrorAction SilentlyContinue)) { if (Test-Path -LiteralPath (Join-Path $sub.FullName 'bruno.json')) { $dirs[$sub.FullName.ToLower()] = $sub.FullName } }
    }
    # drop folders nested inside another selected folder
    $all = @($dirs.Values | Sort-Object Length)
    $keep = @()
    foreach ($a in $all) { $inside = $false; foreach ($k in $keep) { if ($a.StartsWith($k + '\', 'OrdinalIgnoreCase')) { $inside = $true; break } }; if (-not $inside) { $keep += $a } }
    return @($keep)
}

# ---------- where browsers, PuTTY and friends really keep their data ----------

# Chrome/Edge/Brave policies may hold ${user_name}, ${local_app_data}, ... in UserDataDir.
function Expand-MigPolicyPath {
    param([string]$Path)
    $map = @{
        'user_name' = "$env:USERNAME"; 'machine_name' = "$env:COMPUTERNAME"; 'client_name' = "$env:CLIENTNAME"; 'session_name' = "$env:SESSIONNAME"
        'local_app_data' = "$env:LOCALAPPDATA"; 'roaming_app_data' = "$env:APPDATA"; 'profile' = "$env:USERPROFILE"; 'global_app_data' = "$env:ProgramData"
        'documents' = [Environment]::GetFolderPath('MyDocuments'); 'program_files' = "$env:ProgramFiles"; 'windows' = "$env:SystemRoot"
    }
    $out = "$Path"
    foreach ($m in [regex]::Matches($out, '\$\{([A-Za-z_]+)\}')) { $k = $m.Groups[1].Value.ToLower(); if ($map.ContainsKey($k)) { $out = $out.Replace($m.Value, $map[$k]) } }
    return [Environment]::ExpandEnvironmentVariables($out)
}

# Command lines of every running copy of an exe (name without .exe).
function Get-MigProcessCommandLines {
    param([string]$Exe)
    try { return @(Get-CimInstance Win32_Process -Filter ("Name = '{0}.exe'" -f $Exe) -ErrorAction Stop | ForEach-Object { "$($_.CommandLine)" } | Where-Object { $_ }) } catch { return @() }
}

# Every .lnk the user launches from (Desktop, Start menu, taskbar pins) that carries arguments: {File; Target; Arguments}. Cached per process.
function Get-MigShortcutArgs {
    if ($null -ne $script:ShortcutCache) { return $script:ShortcutCache }
    $out = @()
    $dirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'), "$env:APPDATA\Microsoft\Windows\Start Menu", "$env:ProgramData\Microsoft\Windows\Start Menu", "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch")
    try { $sh = New-Object -ComObject WScript.Shell } catch { $script:ShortcutCache = @(); return @() }
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Filter *.lnk -Recurse -File -ErrorAction SilentlyContinue)) {
            try { $s = $sh.CreateShortcut($f.FullName); if ($s.Arguments) { $out += [pscustomobject]@{ File = $f.FullName; Target = "$($s.TargetPath)"; Arguments = "$($s.Arguments)" } } } catch { }
        }
    }
    $script:ShortcutCache = @($out)
    return $script:ShortcutCache
}

$script:BrowserInfo = @{
    chrome   = @{ Default = '%LOCALAPPDATA%\Google\Chrome\User Data';              Policy = 'Software\Policies\Google\Chrome';        Exe = 'chrome' }
    edge     = @{ Default = '%LOCALAPPDATA%\Microsoft\Edge\User Data';             Policy = 'Software\Policies\Microsoft\Edge';       Exe = 'msedge' }
    brave    = @{ Default = '%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data'; Policy = 'Software\Policies\BraveSoftware\Brave';  Exe = 'brave' }
    vivaldi  = @{ Default = '%LOCALAPPDATA%\Vivaldi\User Data';                    Policy = '';                                       Exe = 'vivaldi' }
    chromium = @{ Default = '%LOCALAPPDATA%\Chromium\User Data';                   Policy = 'Software\Policies\Chromium';             Exe = 'chrome' }
    opera    = @{ Default = '%APPDATA%\Opera Software';                            Policy = '';                                       Exe = 'opera' }
    firefox  = @{ Default = '%APPDATA%\Mozilla\Firefox';                           Policy = '';                                       Exe = 'firefox' }
}

# Every folder a browser keeps (or is told to keep) its profiles in - policy, the running process, shortcuts, the default.
# Returns {Path; Via} for folders that exist, the one in force first. People do move these, and that is where the bookmarks are.
function Get-MigBrowserDataDirs {
    param([Parameter(Mandatory)][string]$Browser)
    $b = $script:BrowserInfo["$($Browser.ToLower())"]
    if (-not $b) { return @() }
    $found = New-Object System.Collections.ArrayList
    $add = {
        param($p, $via)
        if (-not $p) { return }
        $p = "$p".Trim().Trim('"').TrimEnd('\')
        if ($p -notmatch '^[A-Za-z]:\\') { return }
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { return }
        foreach ($f in $found) { if ($f.Path -eq $p) { return } }
        [void]$found.Add([pscustomobject]@{ Path = $p; Via = $via })
    }
    $argRe = $(if ($Browser -eq 'firefox') { '(?i)(?:^|\s)-+profile\s+(?:"([^"]+)"|(\S+))' } else { '(?i)--user-data-dir=(?:"([^"]+)"|(\S+))' })
    if ($Browser -eq 'firefox') {
        # profiles.ini: IsRelative=0 entries live anywhere
        $ini = Join-Path (Expand-MigPath $b.Default) 'profiles.ini'
        if (Test-Path -LiteralPath $ini) {
            $path = ''; $rel = '1'
            foreach ($line in @(Get-Content -LiteralPath $ini -ErrorAction SilentlyContinue) + @('[end]')) {
                if ($line -match '^\[') { if ($path -and $rel -eq '0') { & $add ($path -replace '/', '\') 'profiles.ini' }; $path = ''; $rel = '1'; continue }
                if ($line -match '^Path=(.+)$') { $path = $matches[1].Trim() }
                if ($line -match '^IsRelative=(\d)') { $rel = $matches[1] }
            }
        }
    } elseif ($b.Policy) {
        foreach ($hive in 'HKCU', 'HKLM') {
            $v = $null
            try { $v = (Get-ItemProperty -LiteralPath ("Registry::$hive\" + $b.Policy) -Name UserDataDir -ErrorAction Stop).UserDataDir } catch { }
            if ($v) { & $add (Expand-MigPolicyPath "$v") "$hive policy" }
        }
    }
    foreach ($cl in (Get-MigProcessCommandLines $b.Exe)) { if ($cl -match $argRe) { & $add ($matches[1] + $matches[2]) 'running' } }
    $exeRe = '(?i)\\' + [regex]::Escape($b.Exe) + '(_proxy)?\.exe$'
    foreach ($s in (Get-MigShortcutArgs)) { if ($s.Target -match $exeRe -and $s.Arguments -match $argRe) { & $add (Expand-MigPath ($matches[1] + $matches[2])) 'shortcut' } }
    & $add (Expand-MigPath $b.Default) 'default'
    return @($found.ToArray())
}

# Private key files (.ppk) and certificates that PuTTY / KiTTY sessions and Pageant shortcuts point at, wherever they are.
function Get-MigPuttyKeyFiles {
    $out = @{}
    foreach ($root in 'HKCU:\Software\SimonTatham\PuTTY\Sessions', 'HKCU:\Software\9bis.com\KiTTY\Sessions') {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($s in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            foreach ($vn in 'PublicKeyFile', 'DetachedCertificate') {
                $v = "$($s.GetValue($vn))".Trim().Trim('"')
                if (-not $v) { continue }
                $pth = [Environment]::ExpandEnvironmentVariables($v)
                if ($pth -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $pth -PathType Leaf)) { $out[$pth.ToLower()] = $pth }
            }
        }
    }
    foreach ($s in (Get-MigShortcutArgs)) {
        if ($s.Target -notmatch '(?i)pageant\.exe$') { continue }
        foreach ($m in [regex]::Matches($s.Arguments, '"([^"]+\.ppk)"|(\S+\.ppk)')) { $pth = Expand-MigPath ($m.Groups[1].Value + $m.Groups[2].Value); if (Test-Path -LiteralPath $pth -PathType Leaf) { $out[$pth.ToLower()] = $pth } }
    }
    return @($out.Values | Sort-Object)
}

# The paths an entry covers on THIS computer: its catalog paths plus whatever its dynamic rule finds (absolute paths for the latter).
function Get-MigEntryPaths {
    param($Entry)
    $static = @(@(Get-Prop $Entry 'paths' @()) | ForEach-Object { "$_" })
    switch ("$(Get-Prop $Entry 'dynamic' '')") {
        'bruno-collections' { return @(Get-MigBrunoCollectionPaths) }
        'putty-keyfiles' { return @(Get-MigPuttyKeyFiles) }
        'browser-dirs' {
            $known = @{}; foreach ($sp in $static) { $known[(Expand-MigPath $sp).TrimEnd('\').ToLower()] = $true }
            $extra = @()
            foreach ($dd in @(Get-MigBrowserDataDirs "$(Get-Prop $Entry 'browser' '')")) {
                $k = $dd.Path.TrimEnd('\').ToLower()
                if ($known.ContainsKey($k)) { continue }
                $inside = $false; foreach ($kk in @($known.Keys)) { if ($k.StartsWith($kk + '\')) { $inside = $true; break } }   # already packed with its parent
                if (-not $inside) { $extra += $dd.Path; $known[$k] = $true }
            }
            return @($static + $extra)
        }
        default { return $static }
    }
}

# ---------- extra entries: per-backup additions to the catalog (discovered data folders, folders the user added) ----------

function Merge-MigExtraEntries {
    param($Catalog, [string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $Catalog }
    try {
        $extra = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $ids = @{}; foreach ($e in $Catalog.entries) { $ids["$($e.id)"] = $true }
        $list = @($Catalog.entries)
        foreach ($x in @($extra.entries)) { if (-not $ids.ContainsKey("$($x.id)")) { $list += $x } }
        $Catalog.entries = $list
    } catch { }
    return $Catalog
}

$script:ChromiumCacheDirs = @('Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'ShaderCache', 'GrShaderCache', 'blob_storage', 'Service Worker', 'Crashpad', 'logs', 'Logs', 'log', 'tmp', 'temp', 'Temp', 'cache', 'Cache_Data', 'CachedData', 'CachedExtensions', 'component_crx_cache', 'Session Storage', 'Shared Dictionary', 'Network', 'Partitions', 'node_modules', '.git')
$script:AppDataNoise = @('*-updater', '*-nodejs', 'npm-cache', 'pip', 'go-build', 'ms-playwright', 'SquirrelTemp', 'IconCache.db', '.cache', 'node-gyp', 'CEF', 'Downloaded Installations', 'Publishers', 'speech', 'setup', 'ToastNotificationManagerCompat', '*.agreement', 'PUTTY.RND', '.pkg-cache', '*.tmp.*', '*.backup', 'Package Cache', 'D3DSCache', 'NVIDIA', 'AMD', 'AMD_Common', 'Intel', 'Lenovo', 'Dell', 'HP', 'Comms', 'ElevatedDiagnostics', 'Temp', 'CrashDumps', 'ConnectedDevicesPlatform', 'PeerDistRepub', 'PlaceholderTileLogoFolder', 'Packages', 'Microsoft', 'MicrosoftEdge', 'Google', 'Mozilla', 'Adobe', 'Apple Computer', 'Identities', 'Macromedia', 'Sun', 'Oracle', 'Roaming', 'LocalLow', 'Local', 'ntuser.*', 'NTUSER.*', 'Programs', 'VirtualStore', 'Docker', 'docker', 'Steam', 'Zscaler', 'CrowdStrike', 'Tanium', 'Citrix', 'Cisco', 'OneDrive', 'PCMigration*', 'PCMigration-backup', 'Claude', 'claude-cli-nodejs', 'Opera Software', 'bruno', 'Code', 'Cursor', 'Notepad++', 'JetBrains', 'DBeaverData', 'Postman', 'Zoom', 'Slack', 'Greenshot', 'ShareX', 'KeePass', 'FileZilla', 'WinSCP.ini', 'mRemoteNG', 'MobaXterm', 'SAP', 'gnupg', 'gcloud', 'NuGet', 'Everything', 'Joplin', 'azuredatastudio', 'SQL Developer', 'TechSmith', 'PowerToys', 'Arduino15', 'Hewlett-Packard', 'Realtek', 'Synaptics', 'Samsung', 'Canon', 'Epson', 'Brother', 'Logitech', 'Dolby', 'Waves', 'ELAN', 'Conexant', 'Tailscale')

# Data folders of programs no catalog entry knows: one proposed entry per top-level AppData folder.
function Get-MigDiscoveredAppData {
    param($Catalog, [int]$MaxMB = 2048)
    $covered = @()
    foreach ($e in $Catalog.entries) { foreach ($p in @(Get-Prop $e 'paths' @())) { try { $covered += (Expand-MigPath "$p").TrimEnd('\').ToLower() } catch { } } }
    if ($null -eq $script:InstalledCache) { $script:InstalledCache = @(Get-InstalledSoftware) }
    $out = @()
    foreach ($rootPair in @(@{ K = 'roaming'; P = $env:APPDATA; T = '%APPDATA%' }, @{ K = 'local'; P = $env:LOCALAPPDATA; T = '%LOCALAPPDATA%' })) {
        foreach ($dir in (Get-ChildItem -LiteralPath $rootPair.P -Directory -Force -ErrorAction SilentlyContinue)) {
            $n = $dir.Name; $full = $dir.FullName.ToLower()
            if ($dir.Attributes -match 'ReparsePoint') { continue }
            $skip = $false
            foreach ($pat in $script:AppDataNoise) { if ($n -like $pat) { $skip = $true; break } }
            if ($skip) { continue }
            foreach ($c in $covered) { if ($full -eq $c -or $full.StartsWith($c + '\') -or $c.StartsWith($full + '\')) { $skip = $true; break } }
            if ($skip) { continue }
            $st = Get-MigDirStats -Path $dir.FullName -ExcludeDirs $script:ChromiumCacheDirs -ExcludeFiles @('*.log', '*.tmp', '*.pma')
            if ($st.Bytes -lt 1KB) { continue }
            $mb = [math]::Round($st.Bytes / 1MB, 1)
            # which installed program does this folder belong to?
            $prog = $null
            foreach ($s in $script:InstalledCache) {
                $w = ($s.Name -split '[\s\-_]')[0]
                if ($s.Name -match [regex]::Escape($n) -or $s.Publisher -match [regex]::Escape($n) -or ($w.Length -ge 4 -and $n -match ('^' + [regex]::Escape($w)))) { $prog = $s; break }
            }
            $slug = ($n -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
            $entry = [ordered]@{
                id = "appdata-$($rootPair.K)-$slug"; app = "$n (data folder)"; category = 'discovered'; kind = 'files'
                paths = @("$($rootPair.T)\$n"); excludeDirs = @($script:ChromiumCacheDirs); excludeFiles = @('*.log', '*.tmp', '*.pma')
                summary = ('{0} AppData folder, {1} MB. {2}' -f $(if ($rootPair.K -eq 'roaming') { 'Roaming' } else { 'Local' }), $mb, $(if ($prog) { "Belongs to '$($prog.Name)'." } else { 'No matching program in Apps and Features - may be portable or already removed.' }))
                notes = "Discovered at export time; caches are excluded. $(if ($prog) { 'Restored once ' + $prog.Name + ' is installed.' } else { 'Restored on the first run.' })"
                sizeMB = $mb; defaultOff = ($mb -gt 200 -or $st.Bytes -gt ($MaxMB * 1MB)); discovered = $true
            }
            if ($prog) { $entry['appCheck'] = @("uninstall:$([regex]::Escape($prog.Name))"); $entry['appName'] = $prog.Name }
            if ($st.Bytes -gt ($MaxMB * 1MB)) { $entry['summary'] += " Over $MaxMB MB - copy by hand if you need it." }
            $out += [pscustomobject]$entry
        }
    }
    return @($out | Sort-Object { -$_.sizeMB })
}

# Browser extensions present on THIS machine (same shape the export inventory uses).
function Get-MigBrowserExtensions {
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
                    if (-not $settings) { continue }
                    foreach ($p in $settings.PSObject.Properties) {
                        $m = Get-Prop $p.Value 'manifest'; if (-not $m) { continue }
                        if ((Get-Prop $p.Value 'location' 0) -in 5, 10) { continue }
                        $bext += [pscustomobject]@{ Browser = $b.N; Profile = $prof.Name; Id = $p.Name; Name = "$(Get-Prop $m 'name' '')"; Version = "$(Get-Prop $m 'version' '')" }
                    }
                } catch { }
            }
        }
    }
    $ffRoot = "$env:APPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path -LiteralPath $ffRoot) {
        Get-ChildItem -LiteralPath $ffRoot -Directory | ForEach-Object {
            $f = Join-Path $_.FullName 'extensions.json'
            if (Test-Path -LiteralPath $f) { try { $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($a in $j.addons) { if ($a.type -eq 'extension' -and $a.location -eq 'app-profile') { $bext += [pscustomobject]@{ Browser = 'Firefox'; Profile = $_.Name; Id = $a.id; Name = "$($a.defaultLocale.name)"; Version = "$($a.version)" } } } } catch { } }
        }
    }
    return @($bext | Sort-Object Browser, Id -Unique)
}

# Developer tools and global packages on THIS machine, structured.
function Get-MigDevTools {
    $r = [ordered]@{ tools = @(); npmGlobal = @(); pipUser = @(); dotnetTools = @(); psModules = @(); vscodeExtensions = @() }
    foreach ($c in @(@('git', '--version'), @('python', '--version'), @('py', '--version'), @('node', '--version'), @('npm', '--version'), @('java', '-version'), @('dotnet', '--version'), @('pwsh', '--version'), @('docker', '--version'), @('kubectl', 'version', '--client'), @('terraform', '--version'), @('az', '--version'), @('aws', '--version'), @('gh', '--version'), @('code', '--version'), @('mvn', '--version'), @('gradle', '--version'), @('go', 'version'), @('rustc', '--version'), @('ruby', '--version'), @('php', '--version'), @('conda', '--version'), @('uv', '--version'), @('yarn', '--version'), @('pnpm', '--version'))) {
        $cmd = Get-Command $c[0] -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { continue }
        $v = ''; try { $v = "$(& $cmd.Source $c[1..($c.Count - 1)] 2>&1 | Select-Object -First 1)".Trim() } catch { }
        $r.tools += [ordered]@{ name = $c[0]; version = $v; path = $cmd.Source }
    }
    if (Get-Command npm -CommandType Application -ErrorAction SilentlyContinue) { try { $j = (& npm ls -g --depth=0 --json 2>$null | Out-String) | ConvertFrom-Json; foreach ($p in $j.dependencies.PSObject.Properties) { if ($p.Name -ne 'npm') { $r.npmGlobal += [ordered]@{ name = $p.Name; version = "$($p.Value.version)" } } } } catch { } }
    if (Get-Command pip -CommandType Application -ErrorAction SilentlyContinue) { try { $j = (& pip list --user --format=json 2>$null | Out-String) | ConvertFrom-Json; foreach ($p in @($j)) { $r.pipUser += [ordered]@{ name = "$($p.name)"; version = "$($p.version)" } } } catch { } }
    if (Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue) { try { $lines = @(& dotnet tool list -g 2>$null); foreach ($l in ($lines | Select-Object -Skip 2)) { if ($l -match '^(\S+)\s+(\S+)\s+(\S+)') { $r.dotnetTools += [ordered]@{ name = $matches[1]; version = $matches[2] } } } } catch { } }
    try { foreach ($m in (Get-Module -ListAvailable | Where-Object { $_.ModuleBase -like "$env:USERPROFILE*" -or $_.ModuleBase -like "$([Environment]::GetFolderPath('MyDocuments'))*" } | Sort-Object Name -Unique)) { $r.psModules += [ordered]@{ name = $m.Name; version = "$($m.Version)" } } } catch { }
    foreach ($pair in @(@{ Cmd = 'code'; Dir = "$env:USERPROFILE\.vscode\extensions" }, @{ Cmd = 'code-insiders'; Dir = "$env:USERPROFILE\.vscode-insiders\extensions" }, @{ Cmd = 'cursor'; Dir = "$env:USERPROFILE\.cursor\extensions" })) {
        $mf = Join-Path $pair.Dir 'extensions.json'
        if (Test-Path -LiteralPath $mf) { try { foreach ($x in (Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json)) { $r.vscodeExtensions += [ordered]@{ editor = $pair.Cmd; id = "$($x.identifier.id)"; version = "$($x.version)" } } } catch { } }
    }
    return $r
}

# ---------- install checklist state (new PC) ----------
function Get-MigInstallState { param([string]$Source)
    $p = Join-Path $Source "install-state-$env:COMPUTERNAME.json"; $st = @{}
    if (Test-Path -LiteralPath $p) { try { $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($x in $j.items.PSObject.Properties) { $st[$x.Name] = @{ status = "$($x.Value.status)"; at = "$($x.Value.at)"; by = "$($x.Value.by)" } } } catch { } }
    return $st }
function Save-MigInstallState { param([string]$Source, $State)
    $p = Join-Path $Source "install-state-$env:COMPUTERNAME.json"
    @{ computer = $env:COMPUTERNAME; updatedAt = (Get-Date).ToString('o'); items = $State } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $p -Encoding UTF8 }

# ---------- inventory ----------

function Get-InstalledSoftware {
    $roots = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine32' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'User' },
        @{ Path = 'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'User32' }
    )
    $out = @()
    foreach ($r in $roots) {
        if (-not (Test-Path $r.Path)) { continue }
        Get-ChildItem $r.Path -ErrorAction SilentlyContinue | ForEach-Object {
            $p = $null
            try { $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop } catch { return }
            $name = Get-Prop $p 'DisplayName' ''
            if (-not $name) { return }
            $out += [pscustomobject]@{
                Name            = "$name".Trim()
                Version         = "$(Get-Prop $p 'DisplayVersion' '')"
                Publisher       = "$(Get-Prop $p 'Publisher' '')"
                InstallDate     = "$(Get-Prop $p 'InstallDate' '')"
                Scope           = $r.Scope
                SystemComponent = [int](Get-Prop $p 'SystemComponent' 0)
                InstallLocation = "$(Get-Prop $p 'InstallLocation' '')"
                UninstallString = "$(Get-Prop $p 'UninstallString' '')"
                KeyName         = $_.PSChildName
            }
        }
    }
    return @($out | Sort-Object Name, Version -Unique)
}

function Get-StoreApps {
    $out = @()
    try {
        Get-AppxPackage -ErrorAction Stop | Where-Object { -not $_.IsFramework -and -not $_.IsResourcePackage } | ForEach-Object {
            $out += [pscustomobject]@{
                Name            = $_.Name
                Version         = "$($_.Version)"
                Publisher       = $_.Publisher
                SignatureKind   = "$($_.SignatureKind)"
                NonRemovable    = $_.NonRemovable
                PackageFullName = $_.PackageFullName
            }
        }
    } catch { }
    return @($out)
}

# Executables living in the user profile = software installed without admin (per-user or portable).
function Get-PortableApps {
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path $env:USERPROFILE 'Apps'), (Join-Path $env:USERPROFILE 'Tools'), (Join-Path $env:USERPROFILE 'bin'),
        (Join-Path $env:USERPROFILE 'Portable'), (Join-Path $env:USERPROFILE 'scoop\apps'),
        (Join-Path $env:USERPROFILE '.jdks'), (Join-Path $env:LOCALAPPDATA 'JetBrains\Toolbox\apps')
    )
    $out = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $exe = @(Get-ChildItem -LiteralPath $_.FullName -Filter *.exe -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 5)
            if ($exe.Count -gt 0) {
                $st = Get-MigDirStats $_.FullName
                $out += [pscustomobject]@{ Folder = $_.FullName; Executables = (($exe | ForEach-Object { $_.Name }) -join '; '); SizeMB = [math]::Round($st.Bytes / 1MB, 1); LastWrite = $_.LastWriteTime }
            }
        }
    }
    return @($out)
}

Export-ModuleMember -Function *
