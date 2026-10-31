# Waits up to a minute for a "PC Migration" message box and presses the given button (default Yes).
# Used by ui-test.ps1: a modal MessageBox blocks the UI Automation Invoke that raised it, so the answer must come
# from another process.
param([string]$Button = 'Yes', [int]$Seconds = 60)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [Windows.Automation.AutomationElement]
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
    $dlgs = $AE::RootElement.FindAll([Windows.Automation.TreeScope]::Children, (New-Object Windows.Automation.PropertyCondition($AE::NameProperty, 'PC Migration')))
    foreach ($d in $dlgs) {
        if ($d.Current.ClassName -ne '#32770') { continue }
        $b = $d.FindFirst([Windows.Automation.TreeScope]::Children, (New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $Button)))
        if ($b) { $b.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); exit 0 }
    }
    Start-Sleep -Milliseconds 300
}
