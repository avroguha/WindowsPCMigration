# Captures the settings the lab creates on the old PC, so the new PC can be compared after the restore.
param([Parameter(Mandatory)][string]$OutFile)
$f = [ordered]@{ computer = $env:COMPUTERNAME; at = (Get-Date).ToString('o'); reg = [ordered]@{}; files = [ordered]@{}; env = [ordered]@{} }
$regValues = @(
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|AppsUseLightTheme', 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|SystemUsesLightTheme',
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt', 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Hidden', 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|TaskbarAl',
    'HKCU\Control Panel\Mouse|MouseSensitivity', 'HKCU\Console|ScreenColors', 'HKCU\Console|QuickEdit',
    'HKCU\Software\SimonTatham\PuTTY\Sessions\MigLab%20Share|HostName', 'HKCU\Software\SimonTatham\PuTTY\Sessions\MigLab%20Share|PortNumber',
    'HKCU\Software\7-Zip\FM|ShowSystemMenu', 'HKCU\Software\7-Zip\Options|MigLabMarker'
)
foreach ($rv in $regValues) {
    $k, $v = $rv -split '\|'
    $val = $null; try { $val = (Get-Item -LiteralPath ("Registry::" + $k) -ErrorAction Stop).GetValue($v) } catch { }
    $f.reg[$rv] = $(if ($null -eq $val) { '<missing>' } else { "$val" })
}
$files = @("$env:APPDATA\Notepad++\userDefineLang.xml", "$env:APPDATA\Notepad++\config.xml", "$env:APPDATA\Code\User\settings.json", "$env:APPDATA\Code\User\keybindings.json", "$env:APPDATA\Code\User\snippets\miglab.code-snippets", "$env:USERPROFILE\.gitconfig", "$env:APPDATA\Microsoft\Windows\SendTo\MigLab Notes.txt")
$wt = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter 'Microsoft.WindowsTerminal_*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($wt) { $files += "$($wt.FullName)\LocalState\settings.json" }
foreach ($p in $files) {
    $key = $p.Replace($env:USERPROFILE, '%USERPROFILE%')
    if (Test-Path -LiteralPath $p) { $f.files[$key] = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } else { $f.files[$key] = '<missing>' }
}
$ek = Get-Item HKCU:\Environment
$f.env['MIGTEST_VAR'] = "$($ek.GetValue('MIGTEST_VAR'))"
$f.env['Path has tools'] = "$(($ek.GetValue('Path', '', 'DoNotExpandEnvironmentNames')) -like '*%USERPROFILE%\tools*')"
$vsx = "$env:USERPROFILE\.vscode\extensions"
$f.env['vscode-icons extension'] = "$((Test-Path $vsx) -and (@(Get-ChildItem $vsx -Directory -Filter 'vscode-icons-team.vscode-icons*' -ErrorAction SilentlyContinue).Count -gt 0))"
$f | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutFile -Encoding UTF8
"fingerprint written: $OutFile"
