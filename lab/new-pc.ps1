# Runs inside the NEW lab VM (mig-new) as user avro.
#   -Phase restore1   (user)      compare + first restore: nothing installed, app settings must be deferred
#   -Phase install1   (elevated)  install Notepad++ and VS Code only
#   -Phase restore2   (user)      second restore: those two restored, the rest still waiting
#   -Phase install2   (elevated)  install Git, PuTTY, 7-Zip
#   -Phase restore3   (user)      third restore: everything restored; fingerprint and compare with the old PC
param([ValidateSet('restore1', 'install1', 'restore2', 'install2', 'restore3')][string]$Phase, [string]$Share = '\\192.168.5.217\pcmig', [string]$ShareUser = 'mig', [string]$SharePass = 'Lab-mig-share-2026')
$ErrorActionPreference = 'Continue'
& cmdkey.exe /add:192.168.5.217 /user:$ShareUser /pass:$SharePass | Out-Null
$log = Join-Path $Share "logs\$env:COMPUTERNAME-new-$Phase.log"
Start-Transcript -Path $log -Force | Out-Null
"== $Phase on $env:COMPUTERNAME as $env:USERNAME (admin: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators'))) $(Get-Date)"
$env:PCMIG_ROOT = Join-Path $Share 'PCMigration'
$kit = Join-Path $Share 'kit'

$dl = Join-Path $env:TEMP 'miglab-dl'; New-Item -ItemType Directory -Force -Path $dl | Out-Null
$apps = @(
    @{ N = 'Notepad++'; U = 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.7.7/npp.8.7.7.Installer.x64.exe'; F = 'npp.exe'; A = '/S' },
    @{ N = '7-Zip';     U = 'https://www.7-zip.org/a/7z2409-x64.exe'; F = '7z.exe'; A = '/S' },
    @{ N = 'VS Code';   U = 'https://update.code.visualstudio.com/1.96.4/win32-x64/stable'; F = 'vscode.exe'; A = '/VERYSILENT /NORESTART /MERGETASKS=!runcode,addtopath' },
    @{ N = 'Git';       U = 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.2/Git-2.47.1.2-64-bit.exe'; F = 'git.exe'; A = '/VERYSILENT /NORESTART' },
    @{ N = 'PuTTY';     U = 'https://the.earth.li/~sgtatham/putty/0.83/w64/putty-64bit-0.83-installer.msi'; F = 'putty.msi'; A = '/qn' }
)
function Install-Apps { param([string[]]$Names)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($a in $apps) {
        if ($Names -notcontains $a.N) { continue }
        $f = Join-Path $dl $a.F
        try {
            if (-not (Test-Path $f)) { "downloading $($a.N)"; Invoke-WebRequest -Uri $a.U -OutFile $f -UseBasicParsing }
            "installing $($a.N)"
            if ($a.F -like '*.msi') { $p = Start-Process msiexec.exe -ArgumentList "/i `"$f`" $($a.A)" -Wait -PassThru } else { $p = Start-Process $f -ArgumentList $a.A -Wait -PassThru }
            "  exit $($p.ExitCode)"
        } catch { "  FAILED: $($_.Exception.Message)" }
    }
}
function Run-Restore {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'Import-Profile.ps1') -Force 2>&1 | ForEach-Object { "$_" }
    $src = Get-ChildItem $env:PCMIG_ROOT -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    "--- restore-state after this run:"
    $st = Join-Path $src.FullName "restore-state-$env:COMPUTERNAME.json"
    if (Test-Path $st) { $j = Get-Content $st -Raw | ConvertFrom-Json; foreach ($p in ($j.entries.PSObject.Properties | Sort-Object Name)) { "  {0,-26} {1,-9} {2}" -f $p.Name, $p.Value.status, $p.Value.app } }
}

switch ($Phase) {
    'restore1' {
        "--- compare"; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'Compare-Software.ps1') 2>&1 | ForEach-Object { "$_" }
        $src = Get-ChildItem $env:PCMIG_ROOT -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Get-Content (Join-Path $src.FullName 'install-list.md') | Select-Object -First 30
        "--- restore 1"; Run-Restore
    }
    'install1' { Install-Apps 'Notepad++', 'VS Code' }
    'restore2' { Run-Restore }
    'install2' { Install-Apps 'Git', 'PuTTY', '7-Zip' }
    'restore3' {
        Run-Restore
        "--- fingerprint + compare"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'lab\fingerprint.ps1') -OutFile (Join-Path $Share "logs\fingerprint-$env:COMPUTERNAME.json")
        $old = Get-Content (Join-Path $Share 'logs\fingerprint-MIG-OLD.json') -Raw | ConvertFrom-Json
        $new = Get-Content (Join-Path $Share "logs\fingerprint-$env:COMPUTERNAME.json") -Raw | ConvertFrom-Json
        $ok = 0; $bad = 0; $lines = @()
        foreach ($sec in 'reg', 'files', 'env') {
            foreach ($p in $old.$sec.PSObject.Properties) {
                $o = "$($p.Value)"; $n = "$($new.$sec.$($p.Name))"
                if ($o -eq $n) { $ok++; $lines += ('OK    {0,-5} {1}' -f $sec, $p.Name) } else { $bad++; $lines += ('DIFF  {0,-5} {1}: old={2} new={3}' -f $sec, $p.Name, $o, $n) }
            }
        }
        $lines; "VERIFY: $ok match, $bad differ"
        Set-Content -Path (Join-Path $Share 'logs\verify-result.txt') -Value (@("VERIFY: $ok match, $bad differ") + $lines)
    }
}
"done"
Stop-Transcript | Out-Null
