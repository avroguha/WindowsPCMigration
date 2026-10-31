# Drives the wizard through UI Automation (no screen control needed) and captures each page as PNG.
#   powershell -File lab\ui-test.ps1 -Mode export|import -ShotDir <dir> -MigRoot <backup root> -Kit <kit folder>
# The export flow ticks a handful of small entries and packs them; the import flow restores a few of them.
param([ValidateSet('export', 'import')][string]$Mode = 'export', [string]$ShotDir, [string]$MigRoot, [string]$Kit)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null
$env:PCMIG_ROOT = $MigRoot
$proc = Start-Process powershell.exe -ArgumentList @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Kit\Migration-UI.ps1`"") -PassThru -RedirectStandardError "$ShotDir\ui-$Mode.err"
$AE = [Windows.Automation.AutomationElement]
function Get-Win { for ($i = 0; $i -lt 60; $i++) { $ws = $AE::RootElement.FindAll([Windows.Automation.TreeScope]::Children, (New-Object Windows.Automation.PropertyCondition($AE::NameProperty, 'PC Migration'))); foreach ($w in $ws) { if ($w.Current.ClassName -eq 'Window') { return $w } }; Start-Sleep -Milliseconds 500 }; throw 'window not found' }
function Find-El { param($Name, [int]$Wait = 20) for ($i = 0; $i -lt ($Wait * 2); $i++) { $e = $script:win.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $Name))); if ($e) { return $e }; Start-Sleep -Milliseconds 500 }; throw "element '$Name' not found" }
function Click-El { param($Name) $e = Find-El $Name; $e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); Start-Sleep -Milliseconds 800 }
function Toggle-El { param($Name) $e = Find-El $Name; $e.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle(); Start-Sleep -Milliseconds 150 }
function Wait-Enabled { param($Name, [int]$Sec = 600) for ($i = 0; $i -lt $Sec; $i++) { $e = $script:win.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $Name))); if ($e -and $e.Current.IsEnabled) { return }; Start-Sleep -Seconds 1 }; throw "'$Name' never became enabled" }
# a modal "Pack anyway? / Continue?" question blocks the Invoke that raised it: answer it from a separate process
function Start-DialogAnswerer { Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSScriptRoot\answer-dialog.ps1`"") -WindowStyle Hidden }
function Shot { param($Name) $h = [IntPtr]$script:win.Current.NativeWindowHandle; $r = New-Object W+RECT; [void][W]::GetWindowRect($h, [ref]$r)
    $bmp = New-Object Drawing.Bitmap(($r.R - $r.L), ($r.B - $r.T)); $g = [Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc(); [void][W]::PrintWindow($h, $dc, 2); $g.ReleaseHdc($dc); $g.Dispose()
    $bmp.Save("$ShotDir\$Mode-$Name.png"); $bmp.Dispose(); Write-Host "shot $Name" }
function Texts { ($script:win.FindAll([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [Windows.Automation.ControlType]::Text))) | ForEach-Object { $_.Current.Name }) -join ' | ' }

$script:win = Get-Win; Start-Sleep 1
Shot '1-welcome'
if ($Mode -eq 'export') {
    Click-El 'This is my OLD computer'; Shot '2-welcome-selected'
    Click-El 'Next'; Start-Sleep 3; Shot '3-select'
    Click-El 'Select none'
    foreach ($id in 'win-console', 'tools-7zip', 'dev-git', 'win-sendto', 'dev-windows-terminal') { Toggle-El $id }
    Start-Sleep 4; Shot '4-select-chosen'
    Start-DialogAnswerer; Click-El 'Pack my settings'; Start-Sleep 2; Shot '5-running'
    Wait-Enabled 'Continue'; Shot '6-finished'
    Click-El 'Continue'; Start-Sleep 1; Shot '7-done'
    Write-Host (Texts)
    Click-El 'Finish'
} else {
    Click-El 'This is my NEW computer'; Click-El 'Next'; Start-Sleep 2; Shot '2-pick'
    Click-El 'Next'; Wait-Enabled 'Next' 180; Start-Sleep 1; Shot '3-software'
    Click-El 'Next'; Start-Sleep 2; Shot '4-select'
    Click-El 'Select none'; foreach ($id in 'win-console', 'tools-7zip', 'win-sendto') { Toggle-El $id }; Shot '5-select-chosen'
    Start-DialogAnswerer; Click-El 'Restore my settings'; Start-Sleep 2; Shot '6-running'
    Wait-Enabled 'Continue'; Shot '7-finished'
    Click-El 'Continue'; Start-Sleep 1; Shot '8-done'
    Write-Host (Texts)
    Click-El 'Finish'
}
Start-Sleep 1
if (-not $proc.HasExited) { Write-Host 'window still open - killing'; Stop-Process -Id $proc.Id -Force }
$err = Get-Content "$ShotDir\ui-$Mode.err" -Raw -ErrorAction SilentlyContinue; if ($err) { Write-Host "STDERR:`n$err" }
Write-Host 'test done'
