# Runs inside the OLD lab VM (mig-old) as user avro. Two phases because installers need elevation and the
# migration itself must run as a plain user:
#   -Phase install   (elevated task)  install Notepad++, 7-Zip, VS Code, Git, PuTTY
#   -Phase settings  (user task)      create recognisable settings in each, map the share, export, fingerprint
param([ValidateSet('install', 'settings')][string]$Phase, [string]$Share = '\\192.168.5.217\pcmig', [string]$ShareUser = 'mig', [string]$SharePass = 'Lab-mig-share-2026')
$ErrorActionPreference = 'Continue'
$log = Join-Path $Share "logs\$env:COMPUTERNAME-old-$Phase.log"
& cmdkey.exe /add:192.168.5.217 /user:$ShareUser /pass:$SharePass | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Share 'logs') | Out-Null
Start-Transcript -Path $log -Force | Out-Null
"== $Phase on $env:COMPUTERNAME as $env:USERNAME (admin: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators'))) $(Get-Date)"

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
        if ($Names -and $Names -notcontains $a.N) { continue }
        $f = Join-Path $dl $a.F
        try {
            if (-not (Test-Path $f)) { "downloading $($a.N)"; Invoke-WebRequest -Uri $a.U -OutFile $f -UseBasicParsing }
            "installing $($a.N)"
            if ($a.F -like '*.msi') { $p = Start-Process msiexec.exe -ArgumentList "/i `"$f`" $($a.A)" -Wait -PassThru } else { $p = Start-Process $f -ArgumentList $a.A -Wait -PassThru }
            "  exit $($p.ExitCode)"
        } catch { "  FAILED: $($_.Exception.Message)" }
    }
}

if ($Phase -eq 'install') {
    Install-Apps
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' | ForEach-Object { (Get-ItemProperty $_.PSPath).DisplayName } | Where-Object { $_ -match 'Notepad|7-Zip|Visual Studio Code|^Git|PuTTY' } | ForEach-Object { "installed: $_" }
    Stop-Transcript | Out-Null; return
}

# ---------------- settings phase (plain user) ----------------
$reg = 'reg.exe'
# Windows look and feel
& $reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v AppsUseLightTheme /t REG_DWORD /d 0 /f | Out-Null
& $reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v SystemUsesLightTheme /t REG_DWORD /d 0 /f | Out-Null
& $reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' /v HideFileExt /t REG_DWORD /d 0 /f | Out-Null
& $reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' /v Hidden /t REG_DWORD /d 1 /f | Out-Null
& $reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' /v TaskbarAl /t REG_DWORD /d 0 /f | Out-Null
& $reg add 'HKCU\Control Panel\Mouse' /v MouseSensitivity /t REG_SZ /d 15 /f | Out-Null
& $reg add 'HKCU\Console' /v ScreenColors /t REG_DWORD /d 0x1f /f | Out-Null
& $reg add 'HKCU\Console' /v QuickEdit /t REG_DWORD /d 1 /f | Out-Null
# user environment
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\tools" | Out-Null
& $reg add 'HKCU\Environment' /v MIGTEST_VAR /t REG_SZ /d 'hello-from-old-pc' /f | Out-Null
$curPath = (Get-Item HKCU:\Environment).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
if ($curPath -notlike '*%USERPROFILE%\tools*') { & $reg add 'HKCU\Environment' /v Path /t REG_EXPAND_SZ /d ("$curPath;%USERPROFILE%\tools".TrimStart(';')) /f | Out-Null }
# SendTo entry
Set-Content -Path "$env:APPDATA\Microsoft\Windows\SendTo\MigLab Notes.txt" -Value 'sendto marker'
# Notepad++: run once so it writes its config, then customise
$npp = "$env:ProgramFiles\Notepad++\notepad++.exe"
if (Test-Path $npp) {
    $p = Start-Process $npp -PassThru; Start-Sleep 8; [void]$p.CloseMainWindow(); Start-Sleep 5; if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }; Start-Sleep 2
    $cfg = "$env:APPDATA\Notepad++\config.xml"; New-Item -ItemType Directory -Force -Path "$env:APPDATA\Notepad++" | Out-Null
    if (Test-Path $cfg) { [xml]$x = Get-Content $cfg; $n = $x.NotepadPlus.GUIConfigs.GUIConfig | Where-Object { $_.name -eq 'RememberLastSession' }; if ($n) { $n.InnerText = 'no' }; $x.Save($cfg); "notepad++ config customised" }
    else { Set-Content -Path $cfg -Value '<?xml version="1.0" encoding="UTF-8" ?><NotepadPlus><GUIConfigs><GUIConfig name="RememberLastSession">no</GUIConfig></GUIConfigs></NotepadPlus>'; "notepad++ config written (first run did not save one)" }
    Set-Content -Path "$env:APPDATA\Notepad++\userDefineLang.xml" -Value '<NotepadPlus><UserLang name="MigLabLang" ext="miglab"><Settings><Global caseIgnored="no"/></Settings></UserLang></NotepadPlus>'
}
# VS Code
$vsUser = "$env:APPDATA\Code\User"; New-Item -ItemType Directory -Force -Path "$vsUser\snippets" | Out-Null
Set-Content -Path "$vsUser\settings.json" -Value '{ "editor.fontSize": 17, "workbench.colorTheme": "Default Light Modern", "miglab.marker": "settings-from-old-pc" }'
Set-Content -Path "$vsUser\keybindings.json" -Value '[ { "key": "ctrl+alt+m", "command": "workbench.action.togglePanel" } ]'
Set-Content -Path "$vsUser\snippets\miglab.code-snippets" -Value '{ "MigLab": { "prefix": "miglab", "body": [ "migrated snippet" ] } }'
$code = "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
if (Test-Path $code) { & $code --install-extension vscode-icons-team.vscode-icons --force 2>&1 | Select-Object -Last 1 }
# Git
$git = "$env:ProgramFiles\Git\cmd\git.exe"
if (Test-Path $git) { & $git config --global user.name 'Mig Tester'; & $git config --global user.email 'mig@lab.test'; & $git config --global alias.st status; & $git config --global core.autocrlf true }
# PuTTY session
& $reg add 'HKCU\Software\SimonTatham\PuTTY\Sessions\MigLab%20Share' /v HostName /t REG_SZ /d 192.168.5.217 /f | Out-Null
& $reg add 'HKCU\Software\SimonTatham\PuTTY\Sessions\MigLab%20Share' /v Protocol /t REG_SZ /d ssh /f | Out-Null
& $reg add 'HKCU\Software\SimonTatham\PuTTY\Sessions\MigLab%20Share' /v PortNumber /t REG_DWORD /d 22 /f | Out-Null
# 7-Zip
& $reg add 'HKCU\Software\7-Zip\FM' /v ShowSystemMenu /t REG_DWORD /d 1 /f | Out-Null
& $reg add 'HKCU\Software\7-Zip\Options' /v MigLabMarker /t REG_SZ /d yes /f | Out-Null
# Windows Terminal settings (in-box on Win11)
$wt = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter 'Microsoft.WindowsTerminal_*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($wt) { New-Item -ItemType Directory -Force -Path "$($wt.FullName)\LocalState" | Out-Null; Set-Content -Path "$($wt.FullName)\LocalState\settings.json" -Value '{ "copyOnSelect": true, "theme": "dark", "miglab": "terminal-from-old-pc" }' }
"settings created"

# ---------------- export through the kit, with the share as the backup root ----------------
$env:PCMIG_ROOT = Join-Path $Share 'PCMigration'
New-Item -ItemType Directory -Force -Path $env:PCMIG_ROOT | Out-Null
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Share 'kit\Export-Profile.ps1') 2>&1 | ForEach-Object { "$_" }
$exp = Get-ChildItem $env:PCMIG_ROOT -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
"export folder: $($exp.FullName)"

# ---------------- fingerprint for verification on the new PC ----------------
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Share 'kit\lab\fingerprint.ps1') -OutFile (Join-Path $Share "logs\fingerprint-$env:COMPUTERNAME.json")
"done"
Stop-Transcript | Out-Null
