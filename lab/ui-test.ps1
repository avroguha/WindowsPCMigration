# Drives PCMigration.exe through UI Automation (no screen control needed) and captures each page as PNG.
#   powershell -File lab\ui-test.ps1 -Mode export|import -ShotDir <dir> -MigRoot <backup root> -Exe <PCMigration.exe> [-Theme light|dark]
# Export: picks "old computer", scans, selects a handful of small entries, reviews, packs, finishes.
# Import: picks "new computer", chooses the newest backup, runs the install checklist, restores a few of them.
# Every control the test touches carries an AutomationProperties.Name: buttons by their text, tick boxes by catalog id.
param([ValidateSet('export', 'import')][string]$Mode = 'export', [string]$ShotDir, [string]$MigRoot, [string]$Exe, [string]$Theme = '', [string[]]$Ids = @('win-console', 'tools-7zip', 'dev-git', 'win-sendto', 'dev-windows-terminal'))
$ErrorActionPreference = 'Stop'
$Ids = @($Ids | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })   # -File passes "a,b" as one string
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
[void][W]::SetProcessDPIAware()
New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null
$args = @('--root', "`"$MigRoot`""); if ($Theme) { $args += @('--theme', $Theme) }
$proc = Start-Process $Exe -ArgumentList $args -PassThru
$AE = [Windows.Automation.AutomationElement]
function Get-Win { for ($i = 0; $i -lt 60; $i++) { $ws = $AE::RootElement.FindAll([Windows.Automation.TreeScope]::Children, (New-Object Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $proc.Id))); foreach ($w in $ws) { if ($w.Current.ControlType -eq [Windows.Automation.ControlType]::Window) { return $w } }; Start-Sleep -Milliseconds 500 }; throw 'window not found' }
# a page title or a nav item can carry the same text as a button, so every lookup names the control type too
function Cond { param($Name, $Type) if ($Type) { New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $Name)), (New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $Type))) } else { New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $Name) } }
function Find-El { param($Name, [int]$Wait = 20, $Type = $null) for ($i = 0; $i -lt ($Wait * 2); $i++) { $e = $script:win.FindFirst([Windows.Automation.TreeScope]::Descendants, (Cond $Name $Type)); if ($e) { return $e }; Start-Sleep -Milliseconds 500 }; throw "element '$Name' not found" }
function Click-El { param($Name, [int]$Wait = 20) $e = Find-El $Name $Wait ([Windows.Automation.ControlType]::Button); $e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); Start-Sleep -Milliseconds 800 }
function Select-El { param($Name) $e = Find-El $Name 20 ([Windows.Automation.ControlType]::RadioButton); $e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 600 }
function Toggle-El { param($Name) $e = Find-El $Name 20 ([Windows.Automation.ControlType]::CheckBox); $e.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle(); Start-Sleep -Milliseconds 150 }
function Wait-Enabled { param($Name, [int]$Sec = 600) for ($i = 0; $i -lt $Sec; $i++) { $e = $script:win.FindFirst([Windows.Automation.TreeScope]::Descendants, (Cond $Name ([Windows.Automation.ControlType]::Button))); if ($e -and $e.Current.IsEnabled) { return }; Start-Sleep -Seconds 1 }; throw "'$Name' never became enabled" }
function Shot { param($Name) Start-Sleep -Milliseconds 400; $h = [IntPtr]$script:win.Current.NativeWindowHandle; $r = New-Object W+RECT; [void][W]::GetWindowRect($h, [ref]$r)
    $bmp = New-Object Drawing.Bitmap(($r.R - $r.L), ($r.B - $r.T)); $g = [Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc(); [void][W]::PrintWindow($h, $dc, 2); $g.ReleaseHdc($dc); $g.Dispose()
    $bmp.Save("$ShotDir\$Mode-$Name.png"); $bmp.Dispose(); Write-Host "shot $Name" }
function Texts { ($script:win.FindAll([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [Windows.Automation.ControlType]::Text))) | ForEach-Object { $_.Current.Name }) -join ' | ' }

$script:win = Get-Win; Start-Sleep 4
Shot '1-start'
if ($Mode -eq 'export') {
    Select-El 'This is my old computer'; Click-El 'Next'
    Wait-Enabled 'Choose what to take' 300; Shot '2-scan'
    Click-El 'Choose what to take'; Start-Sleep 2; Shot '3-select'
    Click-El 'Select none'
    foreach ($id in $Ids) { try { Toggle-El $id } catch { Write-Host "no $id on this PC" } }
    Start-Sleep 3; Shot '4-select-chosen'
    Click-El 'Review'; Start-Sleep 2; Shot '5-review'
    Click-El 'Pack my settings'; Start-Sleep 1
    try { $d = $script:win.FindFirst([Windows.Automation.TreeScope]::Descendants, (Cond 'Pack anyway' ([Windows.Automation.ControlType]::Button))); if ($d) { Shot '5b-dialog'; $d.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() } } catch { }
    Start-Sleep 3; Shot '6-running'
    Wait-Enabled 'Continue'; Shot '7-finished'
    Click-El 'Continue'; Start-Sleep 2; Shot '8-done'
    Write-Host (Texts)
    Click-El 'Finish'
} else {
    Select-El 'This is my new computer'; Click-El 'Next'; Start-Sleep 3; Shot '2-backup'
    Wait-Enabled 'Next' 60; Click-El 'Next'
    Wait-Enabled 'Next' 300; Start-Sleep 1; Shot '3-install'
    Click-El 'Next'; Wait-Enabled 'Review' 120; Start-Sleep 1; Shot '4-select'
    Click-El 'Select none'; foreach ($id in $Ids) { try { Toggle-El $id } catch { Write-Host "no $id in the backup" } }; Shot '5-select-chosen'
    Click-El 'Review'; Start-Sleep 2; Shot '6-review'
    Click-El 'Restore my settings'; Start-Sleep 1
    try { $d = $script:win.FindFirst([Windows.Automation.TreeScope]::Descendants, (Cond 'Skip them and restore the rest' ([Windows.Automation.ControlType]::Button))); if ($d) { Shot '6b-dialog'; $d.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() } } catch { }
    Start-Sleep 3; Shot '7-running'
    Wait-Enabled 'Continue'; Shot '8-finished'
    Click-El 'Continue'; Start-Sleep 2; Shot '9-done'
    Write-Host (Texts)
    Click-El 'Finish'
}
Start-Sleep 2
if (-not $proc.HasExited) { Write-Host 'window still open - killing'; Stop-Process -Id $proc.Id -Force }
Write-Host 'test done'
