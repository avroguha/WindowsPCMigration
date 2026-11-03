<#
  Migration-UI.ps1 - the guided wizard. Double-click "Start Migration.cmd" (it runs this with -STA).
  It only drives Export-Profile.ps1 / Compare-Software.ps1 / Import-Profile.ps1 in a hidden child process
  and shows progress; all the actual work lives in those scripts.
#>
param([string]$ScriptDir)
$ErrorActionPreference = 'Stop'
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $ScriptDir 'MigrationCommon.psm1') -Force

$script:catalog  = Get-MigCatalog (Join-Path $ScriptDir 'catalog.json')
$script:oneDrive = Get-MigOneDriveRoot
$script:migRoot  = Get-MigRoot
$script:state = @{ Mode = $null; Destination = $null; Source = $null; Manifest = $null; SelectedIds = @(); SecretIds = @(); Password = $null; Proc = $null; OutFile = $null; Timer = $null; SizeJob = $null; SizeLabels = @{}; Compare = $null; Done = $false }
$catTitles = @{ discovered = 'Other programs found on this PC (their data folders)'; custom = 'Folders you added'; windows = 'Windows look, feel and input'; office = 'Microsoft Office and Outlook'; browser = 'Browsers (bookmarks, extensions, history)'; dev = 'Developer tools'; tools = 'Utilities'; data = 'Data and database tools'; comms = 'Mail, chat and meetings'; secrets = 'Keys and passwords' }
$catOrder = 'windows', 'office', 'browser', 'dev', 'tools', 'data', 'comms', 'discovered', 'custom'
$script:customEntries = @(); $script:discoveredCache = $null

# ------------------------------------------------------------------ window shell
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC Migration" Width="1000" Height="720" MinWidth="860" MinHeight="620" WindowStartupLocation="CenterScreen"
        Background="#F3F4F6" FontFamily="Segoe UI" FontSize="14" Foreground="#111827">
  <Window.Resources>
    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Background" Value="#2563EB"/><Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="22,10"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="14"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1D4ED8"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Background" Value="#BFDBFE"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Secondary" TargetType="Button">
      <Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#111827"/><Setter Property="Padding" Value="18,9"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="#D1D5DB" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#F3F4F6"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#9CA3AF"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/><Setter Property="CornerRadius" Value="12"/><Setter Property="Padding" Value="22,18"/><Setter Property="Margin" Value="0,0,0,14"/>
      <Setter Property="BorderBrush" Value="#E5E7EB"/><Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Margin" Value="0,5,0,5"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="ProgressBar"><Setter Property="Height" Value="10"/><Setter Property="Foreground" Value="#2563EB"/><Setter Property="Background" Value="#E5E7EB"/><Setter Property="BorderThickness" Value="0"/></Style>
    <Style TargetType="PasswordBox"><Setter Property="Padding" Value="8,6"/><Setter Property="BorderBrush" Value="#D1D5DB"/><Setter Property="Width" Value="260"/><Setter Property="HorizontalAlignment" Value="Left"/></Style>
    <Style TargetType="ComboBox"><Setter Property="Padding" Value="8,6"/><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="MinWidth" Value="420"/></Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Top" Background="White" Padding="36,22" BorderBrush="#E5E7EB" BorderThickness="0,0,0,1">
      <Grid>
        <StackPanel><TextBlock Name="Title" FontSize="24" FontWeight="SemiBold"/><TextBlock Name="Subtitle" Foreground="#6B7280" Margin="0,4,0,0" TextWrapping="Wrap"/></StackPanel>
        <StackPanel HorizontalAlignment="Right" VerticalAlignment="Top">
          <TextBlock Name="StepLabel" HorizontalAlignment="Right" Foreground="#2563EB" FontWeight="SemiBold"/>
          <TextBlock Name="VersionLabel" HorizontalAlignment="Right" Foreground="#9CA3AF" FontSize="12" Margin="0,4,0,0"/>
        </StackPanel>
      </Grid>
    </Border>
    <Border DockPanel.Dock="Bottom" Background="White" Padding="36,14" BorderBrush="#E5E7EB" BorderThickness="0,1,0,0">
      <Grid>
        <TextBlock Name="FooterNote" Foreground="#6B7280" VerticalAlignment="Center" TextWrapping="Wrap" MaxWidth="560" HorizontalAlignment="Left"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button Name="BackBtn" Style="{StaticResource Secondary}" Content="Back" Margin="0,0,10,0"/>
          <Button Name="NextBtn" Style="{StaticResource Primary}" Content="Next"/>
        </StackPanel>
      </Grid>
    </Border>
    <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="36,24,36,10"><ContentControl Name="Page"/></ScrollViewer>
  </DockPanel>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:win = [Windows.Markup.XamlReader]::Load($reader)
foreach ($n in 'Title', 'Subtitle', 'StepLabel', 'VersionLabel', 'FooterNote', 'BackBtn', 'NextBtn', 'Page') { Set-Variable -Name $n -Value $script:win.FindName($n) -Scope Script }
$script:kitVersion = Get-MigVersion
$script:win.Title = "PC Migration $script:kitVersion"
$script:VersionLabel.Text = "Version $script:kitVersion"
[Windows.Automation.AutomationProperties]::SetName($script:win, 'PC Migration')

# ------------------------------------------------------------------ small builders
function New-Text { param([string]$Text, [int]$Size = 14, [string]$Weight = 'Normal', [string]$Color = '#111827', [string]$Margin = '0,0,0,0')
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $Text; $t.FontSize = $Size; $t.FontWeight = $Weight; $t.Foreground = $Color; $t.TextWrapping = 'Wrap'; $t.Margin = $Margin; return $t }
function New-Card { param([string]$Heading, [string]$Sub)
    $b = New-Object Windows.Controls.Border; $b.Style = $script:win.Resources['Card']
    $sp = New-Object Windows.Controls.StackPanel; $b.Child = $sp
    if ($Heading) { [void]$sp.Children.Add((New-Text $Heading 16 'SemiBold')) }
    if ($Sub) { [void]$sp.Children.Add((New-Text $Sub 13 'Normal' '#6B7280' '0,2,0,8')) }
    return $b }
function New-Button { param([string]$Text, [string]$Style = 'Secondary', [scriptblock]$OnClick)
    $btn = New-Object Windows.Controls.Button; $btn.Content = $Text; $btn.Style = $script:win.Resources[$Style]; $btn.Margin = '0,6,10,0'; $btn.HorizontalAlignment = 'Left'
    if ($OnClick) { $btn.Add_Click($OnClick) }; return $btn }
function New-Stack { param([string]$Orientation = 'Vertical') $s = New-Object Windows.Controls.StackPanel; $s.Orientation = $Orientation; return $s }
function Set-Header { param([string]$T, [string]$S, [string]$Step) $script:Title.Text = $T; $script:Subtitle.Text = $S; $script:StepLabel.Text = $Step }
function Set-Footer { param([string]$Next = 'Next', [bool]$NextEnabled = $true, [bool]$BackEnabled = $true, [string]$Note = '', [scriptblock]$OnNext, [scriptblock]$OnBack)
    $script:NextBtn.Content = $Next; $script:NextBtn.IsEnabled = $NextEnabled; $script:BackBtn.IsEnabled = $BackEnabled; $script:FooterNote.Text = $Note
    $script:onNext = $OnNext; $script:onBack = $OnBack }
$script:NextBtn.Add_Click({ if ($script:onNext) { try { & $script:onNext } catch { [Windows.MessageBox]::Show("$($_.Exception.Message)", 'PC Migration', 'OK', 'Error') | Out-Null } } })
$script:BackBtn.Add_Click({ if ($script:onBack) { & $script:onBack } })
function Stop-Background { if ($script:state.Timer) { $script:state.Timer.Stop(); $script:state.Timer = $null }; if ($script:state.SizeJob) { Remove-Job $script:state.SizeJob -Force -ErrorAction SilentlyContinue; $script:state.SizeJob = $null } }
function Format-MB { param($mb) if ($null -eq $mb) { return '' } elseif ($mb -lt 0.05) { return 'tiny' } elseif ($mb -lt 1) { return ('{0:N0} KB' -f ($mb * 1024)) } elseif ($mb -lt 1024) { return ('{0:N0} MB' -f $mb) } else { return ('{0:N1} GB' -f ($mb / 1024)) } }
function Get-Exports {
    if (-not $script:migRoot -or -not (Test-Path -LiteralPath $script:migRoot)) { return @() }
    $out = @()
    foreach ($d in (Get-ChildItem -LiteralPath $script:migRoot -Directory | Sort-Object LastWriteTime -Descending)) {
        $m = Join-Path $d.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $m)) { continue }
        try { $j = Get-Content -LiteralPath $m -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $out += [pscustomobject]@{ Path = $d.FullName; Computer = "$($j.computer)"; User = "$($j.user)"; Created = ([datetime]$j.createdAt); Packages = @($j.entries).Count; Secrets = @($j.secrets).Count; Manifest = $j
                                   Label = ('{0}  -  {1} ({2}), {3:dd MMM yyyy HH:mm}, {4} items' -f $d.Name, $j.computer, $j.user, ([datetime]$j.createdAt), @($j.entries).Count) }
    }
    return $out
}
function Get-ManualSteps { param([string]$ReportPath)
    if (-not (Test-Path -LiteralPath $ReportPath)) { return @() }
    $lines = Get-Content -LiteralPath $ReportPath -Encoding UTF8; $in = $false; $out = @()
    foreach ($l in $lines) { if ($l -like '## Manual steps*') { $in = $true; continue }; if ($in -and $l -like '## *') { break }; if ($in -and $l -like '- *') { $out += ($l.Substring(2) -replace '\*\*', '' -replace '`', '') } }
    return $out
}

# Runs one of the scripts hidden and streams its output into a progress page.
function Start-Worker { param([string]$Script, [string[]]$Arguments, [string]$Password)
    $out = Join-Path $env:TEMP ('pcmig-ui-' + [guid]::NewGuid().ToString('N') + '.log')
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $ScriptDir $Script) + '"')) + $Arguments
    if ($Password) { $env:PCMIG_SECRET_PW = $Password }
    try { $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError ($out + '.err') }
    finally { $env:PCMIG_SECRET_PW = $null }
    $null = $p.Handle   # without this, ExitCode is never populated
    $script:state.Proc = $p; $script:state.OutFile = $out
}

# ------------------------------------------------------------------ pages
function Show-Welcome {
    Stop-Background
    Set-Header 'PC Migration' 'Moves your settings from one computer to another through OneDrive. No admin rights, no USB stick.' 'Step 1 of 4'
    $root = New-Stack
    $locCard = New-Card 'Where the backup lives' $(if ($script:migRoot) { $script:migRoot } else { 'OneDrive was not found on this computer. Pick a folder both computers can reach - a network share, for example.' })
    if (-not $script:migRoot) { $locCard.Background = '#FEF2F2' }
    [void]$locCard.Child.Children.Add((New-Button 'Change folder...' 'Secondary' {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog; $dlg.Description = 'Pick a folder that BOTH computers can reach (OneDrive, a network share, ...). A PCMigration folder is created inside it.'; $dlg.ShowNewFolderButton = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:migRoot = Join-Path $dlg.SelectedPath 'PCMigration'; $env:PCMIG_ROOT = $script:migRoot; New-Item -ItemType Directory -Force -Path $script:migRoot | Out-Null; Show-Welcome }
    }))
    [void]$root.Children.Add($locCard)
    $net = Test-MigNetwork
    $netText = $(if ($net.Available) { 'Network: connected' + $(if ($net.Profiles.Count) { ' (' + ($net.Profiles -join '; ') + ')' } else { '' }) } else { 'Network: NOT connected.' })
    $netText += $(if ($net.OneDriveRunning) { '   OneDrive: running.' } else { '   OneDrive: not running - start it so the backup can sync.' })
    $netCard = New-Card $null $null; [void]$netCard.Child.Children.Add((New-Text $netText 13 'SemiBold' $(if ($net.Available) { '#047857' } else { '#B45309' })))
    [void]$netCard.Child.Children.Add((New-Text 'Packing into OneDrive works without a network (the upload happens later). Restoring on the new PC needs the network while files are still in the cloud; if it drops, the wizard pauses and resumes by itself.' 12 'Normal' '#6B7280' '0,4,0,0'))
    if (-not $net.Available) { $netCard.Background = '#FFFBEB' }
    [void]$root.Children.Add($netCard)
    [void]$root.Children.Add((New-Text 'Which computer is this?' 16 'SemiBold' '#111827' '0,4,0,10'))
    $grid = New-Object Windows.Controls.Grid
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition)); $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
    $script:modeCards = @{}
    $i = 0
    foreach ($opt in @(@{ M = 'export'; T = 'This is my OLD computer'; S = 'Pack up my settings, my list of installed programs and my preferences, and put them in OneDrive.' }, @{ M = 'import'; T = 'This is my NEW computer'; S = 'Show me what to install, then bring my settings here from OneDrive.' })) {
        $c = New-Card $opt.T $opt.S; $c.Margin = '0'; $c.MinHeight = 120; $c.BorderThickness = 2
        $btn = New-Object Windows.Controls.Button; $btn.Content = $c; $btn.Tag = $opt.M; $btn.Cursor = 'Hand'; $btn.Background = 'Transparent'; $btn.BorderThickness = 0; $btn.Padding = 0; $btn.HorizontalContentAlignment = 'Stretch'; $btn.Margin = if ($i -eq 0) { '0,0,8,14' } else { '8,0,0,14' }
        [Windows.Automation.AutomationProperties]::SetName($btn, $opt.T)
        $btn.Add_Click({ param($s, $e) $script:state.Mode = $s.Tag; foreach ($k in $script:modeCards.Keys) { $cc = $script:modeCards[$k]; if ($k -eq $s.Tag) { $cc.BorderBrush = '#2563EB'; $cc.Background = '#EFF6FF' } else { $cc.BorderBrush = '#E5E7EB'; $cc.Background = 'White' } }; $script:NextBtn.IsEnabled = $true })
        [Windows.Controls.Grid]::SetColumn($btn, $i); [void]$grid.Children.Add($btn); $script:modeCards[$opt.M] = $c; $i++
    }
    [void]$root.Children.Add($grid)
    $exports = Get-Exports
    foreach ($ex in $exports) {
        $sp = Join-Path $ex.Path "install-state-$env:COMPUTERNAME.json"
        if (Test-Path -LiteralPath $sp) {
            $st = Get-MigInstallState $ex.Path; $done = @($st.Values | Where-Object { $_.status -eq 'installed' }).Count; $skipped = @($st.Values | Where-Object { $_.status -eq 'skipped' }).Count
            $rc = New-Card 'Continue where you left off' "A restore onto this computer from the backup of $($ex.Computer) is in progress: $done installed, $skipped skipped on the install list."; $rc.Background = '#EFF6FF'
            $rc.Tag = $ex
            $btn = New-Button 'Continue the install list and restore' 'Primary' { }
            $btn.Tag = $ex
            $btn.Add_Click({ param($b, $e) $ex2 = $b.Tag; $script:state.Mode = 'import'; $script:state.Source = $ex2.Path; $script:state.Manifest = $ex2.Manifest; $script:catalog = Merge-MigExtraEntries -Catalog $script:catalog -Path (Join-Path $ex2.Path 'extra-entries.json'); Show-Software })
            [void]$rc.Child.Children.Add($btn); [void]$root.Children.Add($rc)
            break
        }
    }
    $hint = if ($exports.Count -gt 0) { $e = $exports[0]; "Found a backup from $($e.Computer) made $($e.Created.ToString('dd MMM yyyy HH:mm')) in OneDrive." + $(if ($e.Computer -ne $env:COMPUTERNAME) { ' This looks like your new computer.' } else { '' }) } else { 'No backup in OneDrive yet, so this is probably your old computer.' }
    [void]$root.Children.Add((New-Text $hint 13 'Normal' '#6B7280' '0,0,0,10'))
    $how = New-Card 'How it works' ''
    foreach ($l in @('1.  On the OLD computer: tick what to take, press Pack. Everything lands in OneDrive\PCMigration.', '2.  Wait for OneDrive to finish syncing (green tick on the folder).', '3.  On the NEW computer: install the programs the wizard lists, then press Restore.', '4.  Sign out and back in. A short list tells you the few things only you can do (saved passwords, default apps).')) { [void]$how.Child.Children.Add((New-Text $l 13 'Normal' '#374151' '0,3,0,3')) }
    [void]$root.Children.Add($how)
    $script:Page.Content = $root
    if ($script:state.Mode) { $script:modeCards[$script:state.Mode].BorderBrush = '#2563EB'; $script:modeCards[$script:state.Mode].Background = '#EFF6FF' }
    Set-Footer 'Next' ([bool]$script:state.Mode -and [bool]$script:migRoot) $false '' { if ($script:state.Mode -eq 'export') { Show-ExportSelect } else { Show-PickSource } } $null
}

# shared: a category card with a header checkbox and rows; returns the Border. $rows = list of @{Id; Name; Note; SizeMB; Checked}
function New-SelectionCard { param([string]$Heading, $Rows, [string]$Sub = '')
    $card = New-Card $null $null
    $sp = $card.Child
    $head = New-Object Windows.Controls.CheckBox; $head.FontSize = 16; $head.FontWeight = 'SemiBold'; $head.Content = $Heading; $head.IsChecked = $true; $head.Margin = '0,0,0,4'; [Windows.Automation.AutomationProperties]::SetName($head, 'group:' + $Heading)
    [void]$sp.Children.Add($head)
    if ($Sub) { [void]$sp.Children.Add((New-Text $Sub 12 'Normal' '#6B7280' '24,0,0,6')) }
    $children = @()
    foreach ($r in $Rows) {
        $g = New-Object Windows.Controls.Grid; $g.Margin = '24,0,0,0'
        $g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition)); $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = [Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($cd)
        $cb = New-Object Windows.Controls.CheckBox; $cb.Tag = $r.Id; $cb.IsChecked = [bool]$r.Checked; [Windows.Automation.AutomationProperties]::SetName($cb, $r.Id)
        if ($r.ContainsKey('Enabled') -and -not $r.Enabled) { $cb.IsEnabled = $false }
        $inner = New-Stack; [void]$inner.Children.Add((New-Text $r.Name 14 'Normal'))
        if ($r.Summary) { [void]$inner.Children.Add((New-Text $r.Summary 12 'Normal' '#6B7280')) }
        if ($r.ContainsKey('Badge') -and $r.Badge) { [void]$inner.Children.Add((New-Text $r.Badge 12 'SemiBold' $(if ($r.ContainsKey('BadgeColor')) { $r.BadgeColor } else { '#B45309' }) '0,2,0,0')) }
        if ($r.Note) { $cb.ToolTip = $r.Note }
        $cb.Content = $inner
        $sz = New-Text (Format-MB $r.SizeMB) 12 'Normal' '#9CA3AF' '16,8,0,0'; $sz.VerticalAlignment = 'Top'; $sz.MinWidth = 60; $sz.TextAlignment = 'Right'
        if ($null -eq $r.SizeMB) { $script:state.SizeLabels[$r.Id] = $sz }
        [Windows.Controls.Grid]::SetColumn($cb, 0); [Windows.Controls.Grid]::SetColumn($sz, 1)
        [void]$g.Children.Add($cb); [void]$g.Children.Add($sz); [void]$sp.Children.Add($g)
        $children += $cb
    }
    $head.Tag = $children
    $head.Add_Click({ param($s, $e) foreach ($c in $s.Tag) { $c.IsChecked = [bool]$s.IsChecked } })
    foreach ($c in $children) { $c.Tag = @{ Id = $c.Tag; Head = $head }; $c.Add_Click({ param($s, $e) $h = $s.Tag.Head; $all = @($h.Tag); $on = @($all | Where-Object { $_.IsChecked }).Count; $h.IsChecked = $(if ($on -eq 0) { $false } elseif ($on -eq $all.Count) { $true } else { $null }) }) }
    $head.IsChecked = $(if (@($children | Where-Object { $_.IsChecked }).Count -eq $children.Count) { $true } elseif (@($children | Where-Object { $_.IsChecked }).Count -eq 0) { $false } else { $null })
    return $card
}
function Get-CheckedIds { param($Root)
    $ids = @()
    $stack = New-Object System.Collections.Stack; $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        if ($n -is [Windows.Controls.CheckBox] -and $n.Tag -is [hashtable] -and $n.IsChecked) { $ids += $n.Tag.Id }
        if ($n -is [Windows.Controls.Panel]) { foreach ($c in $n.Children) { $stack.Push($c) } }
        elseif ($n -is [Windows.Controls.Decorator]) { if ($n.Child) { $stack.Push($n.Child) } }
        elseif ($n -is [Windows.Controls.ContentControl] -and $n.Content -is [Windows.UIElement]) { $stack.Push($n.Content) }
    }
    return $ids
}

function Show-ExportSelect {
    Stop-Background
    Set-Header 'What do you want to take?' 'Only things found on this computer are listed. Untick anything you do not need. Sizes fill in as the wizard measures them.' 'Step 2 of 4'
    $root = New-Stack
    $present = @(); $secret = @()
    foreach ($e in $script:catalog.entries) {
        $found = $false
        switch ("$(Get-Prop $e 'dynamic' '')") {
            'hkcu-vendors' { $found = (@(Get-MigOtherVendorKeys $script:catalog).Count -gt 0) }
            'bruno-collections' { $found = (@(Get-MigBrunoCollectionPaths).Count -gt 0) }
            'putty-keyfiles' { $found = (@(Get-MigPuttyKeyFiles).Count -gt 0) }
            'browser-dirs' { foreach ($p in @(Get-MigEntryPaths $e)) { if (Test-Path -LiteralPath (Expand-MigPath $p)) { $found = $true; break } } }
            default {
                if ((Get-Prop $e 'kind' 'files') -eq 'files') { foreach ($p in @(Get-Prop $e 'paths' @())) { if (Test-Path -LiteralPath (Expand-MigPath $p)) { $found = $true; break } } }
                else { foreach ($k in @(Get-Prop $e 'keys' @())) { if (Test-MigRegKey $k) { $found = $true; break } } }
            }
        }
        if (-not $found) { continue }
        if (Get-Prop $e 'secret' $false) { $secret += $e } else { $present += $e }
    }
    $tools = New-Stack 'Horizontal'
    [void]$tools.Children.Add((New-Button 'Select all' 'Secondary' { foreach ($cb in (Find-Checkboxes $script:Page.Content)) { if ($cb.Tag -is [hashtable] -or $cb.FontSize -eq 16) { $cb.IsChecked = $true } } }))
    [void]$tools.Children.Add((New-Button 'Select none' 'Secondary' { foreach ($cb in (Find-Checkboxes $script:Page.Content)) { if ($cb.Tag -is [hashtable] -or $cb.FontSize -eq 16) { $cb.IsChecked = $false } } }))
    [void]$root.Children.Add($tools)
    # open editors: unsaved tabs/documents are on disk only once the program has written them
    $script:editorMap = @{ 'Postman' = 'Postman'; 'MobaXterm' = 'MobaXterm'; 'Notepad' = 'Notepad'; 'notepad++' = 'Notepad++'; 'Code' = 'VS Code'; 'WINWORD' = 'Word'; 'EXCEL' = 'Excel'; 'POWERPNT' = 'PowerPoint'; 'OUTLOOK' = 'Outlook'; 'msedge' = 'Edge'; 'chrome' = 'Chrome'; 'firefox' = 'Firefox' }
    $script:openCard = New-Card 'Save your work and close these programs first' ''; $script:openCard.Background = '#FFFBEB'
    $script:openText = New-Text '' 13 'Normal' '#374151'; [void]$script:openCard.Child.Children.Add($script:openText)
    [void]$script:openCard.Child.Children.Add((New-Text 'Unsaved tabs in Notepad and Notepad++, unsaved editors in VS Code and Office AutoRecover copies are packed too - but only what the program has already written to disk. Closing the program asks you to save and flushes the rest.' 12 'Normal' '#6B7280' '0,4,0,0'))
    [void]$script:openCard.Child.Children.Add((New-Button 'Close them for me (you will be asked to save)' 'Secondary' { foreach ($pn in $script:openProcs) { Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() } }; Start-Sleep -Seconds 3; & $script:refreshOpen }))
    $script:refreshOpen = {
        $procs = @($script:editorMap.Keys | Where-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
        $script:openProcs = $procs
        if ($procs.Count -gt 0) { $script:openText.Text = 'Open right now: ' + (($procs | ForEach-Object { $script:editorMap[$_] } | Sort-Object -Unique) -join ', ') + '.'; $script:openCard.Visibility = 'Visible' } else { $script:openCard.Visibility = 'Collapsed' }
    }
    & $script:refreshOpen
    [void]$root.Children.Add($script:openCard)
    $script:state.SizeLabels = @{}
    foreach ($cat in $catOrder) {
        $rows = @($present | Where-Object { (Get-Prop $_ 'category' '') -eq $cat } | ForEach-Object {
            $badge = ''; $ent = $_
            switch ("$(Get-Prop $_ 'dynamic' '')") {
                'putty-keyfiles' { $kf = @(Get-MigPuttyKeyFiles); $badge = "$($kf.Count) key file(s): " + (($kf | Select-Object -First 3) -join '; ') + $(if ($kf.Count -gt 3) { '; ...' } else { '' }) }
                'browser-dirs' { $bd = @(@(Get-MigBrowserDataDirs "$(Get-Prop $ent 'browser' '')") | Where-Object { $_.Via -ne 'default' }); if ($bd.Count) { $badge = 'Also found outside the default location, taken too: ' + (($bd | ForEach-Object { "$($_.Path) ($($_.Via))" }) -join '; ') } }
                'hkcu-vendors' { $vk = @(Get-MigOtherVendorKeys $script:catalog); $badge = "$($vk.Count) program(s): " + (($vk | Select-Object -First 12 | ForEach-Object { $_.Vendor }) -join ', ') + $(if ($vk.Count -gt 12) { ', ...' } else { '' }) }
                'bruno-collections' { $bp = @(Get-MigBrunoCollectionPaths); $badge = "$($bp.Count) collection folder(s): " + (($bp | Select-Object -First 4) -join '; ') }
            }
            @{ Id = $_.id; Name = $_.app; Summary = (Get-Prop $_ 'summary' ''); Note = (Get-Prop $_ 'notes' ''); SizeMB = $(if ((Get-Prop $_ 'kind' 'files') -eq 'registry') { 0.01 } else { $null }); Checked = (-not (Get-Prop $_ 'defaultOff' $false)); Badge = $badge; BadgeColor = '#6B7280' } })
        if ($rows.Count -eq 0) { continue }
        [void]$root.Children.Add((New-SelectionCard $catTitles[$cat] $rows))
    }
    # programs the catalog does not know: their AppData folders, proposed one by one
    if ($null -eq $script:discoveredCache) { $script:discoveredCache = @(Get-MigDiscoveredAppData $script:catalog) }
    $script:extraById = @{}
    foreach ($d in $script:discoveredCache) { $script:extraById["$($d.id)"] = $d }
    if ($script:discoveredCache.Count -gt 0) {
        $rows = @($script:discoveredCache | ForEach-Object { @{ Id = "$($_.id)"; Name = "$($_.app)"; Summary = "$($_.summary)"; Note = "$($_.notes)"; SizeMB = [double]$_.sizeMB; Checked = (-not $_.defaultOff) } })
        [void]$root.Children.Add((New-SelectionCard $catTitles['discovered'] $rows 'Found by looking at AppData. Big ones and ones without a matching program are unticked; tick what you recognise. Caches are left out automatically.'))
    }
    # folders the user adds (collections, project folders outside OneDrive...); remembered from the last backup of this PC
    if ($script:customEntries.Count -eq 0) {
        $prevExp = @(Get-Exports | Where-Object { $_.Computer -eq $env:COMPUTERNAME } | Select-Object -First 1)
        if ($prevExp.Count -gt 0) { $pf = Join-Path $prevExp[0].Path 'extra-entries.json'; if (Test-Path -LiteralPath $pf) { try { $script:customEntries = @((Get-Content -LiteralPath $pf -Raw -Encoding UTF8 | ConvertFrom-Json).entries | Where-Object { "$($_.category)" -eq 'custom' }) } catch { } } }
    }
    foreach ($c in $script:customEntries) { $script:extraById["$($c.id)"] = $c }
    $cc = New-Card $catTitles['custom'] 'Anything else that lives outside OneDrive: a folder of API collections, scripts, a project. Restored to the same path on the new PC.'
    if ($script:customEntries.Count -gt 0) {
        $rows = @($script:customEntries | ForEach-Object { @{ Id = "$($_.id)"; Name = "$($_.app)"; Summary = "$($_.summary)"; Note = ''; SizeMB = $null; Checked = $true } })
        $inner = New-SelectionCard 'Folders' $rows; $inner.Margin = '0'; $inner.Padding = '0'; $inner.BorderThickness = 0; [void]$cc.Child.Children.Add($inner)
    }
    [void]$cc.Child.Children.Add((New-Button 'Add a folder...' 'Secondary' {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog; $dlg.Description = 'Pick a folder to carry to the new PC (it is restored to the same path).'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $pth = $dlg.SelectedPath.TrimEnd('\'); $n = $script:customEntries.Count + 1
            $st = Get-MigDirStats $pth
            $script:customEntries += [pscustomobject]@{ id = ('custom-{0}-{1}' -f $n, (($pth -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower() -replace '^(.{0,40}).*$', '$1')); app = (Split-Path -Leaf $pth); category = 'custom'; kind = 'files'; paths = @($pth); excludeDirs = @('node_modules', '.git', '.venv', '__pycache__'); summary = ('{0}  ({1:N0} MB)' -f $pth, ($st.Bytes / 1MB)); notes = 'Folder you added in the wizard; restored to the same path (adjusted if the username differs).' }
            Show-ExportSelect
        }
    }))
    [void]$root.Children.Add($cc)
    if ($secret.Count -gt 0) {
        $rows = @($secret | ForEach-Object { @{ Id = $_.id; Name = $_.app; Summary = (Get-Prop $_ 'summary' ''); Note = (Get-Prop $_ 'notes' ''); SizeMB = $null; Checked = $false } })
        $sc = New-SelectionCard 'Keys and passwords (optional, encrypted)' $rows 'Private keys, login tokens and saved passwords. They are only taken if you tick them, and are always encrypted with a password you choose here. Alternative: create new keys on the new computer.'
        $pw = New-Stack 'Horizontal'; $pw.Margin = '24,8,0,0'
        [void]$pw.Children.Add((New-Text 'Password for the encrypted bundle:' 13 'Normal' '#374151' '0,8,10,0'))
        $script:pw1 = New-Object Windows.Controls.PasswordBox; $script:pw2 = New-Object Windows.Controls.PasswordBox; $script:pw2.Margin = '10,0,0,0'
        [void]$pw.Children.Add($script:pw1); [void]$pw.Children.Add((New-Text 'repeat:' 13 'Normal' '#374151' '14,8,0,0')); [void]$pw.Children.Add($script:pw2)
        [void]$sc.Child.Children.Add($pw)
        [void]$root.Children.Add($sc)
    } else { $script:pw1 = $null }
    $script:Page.Content = $root
    # background size measurement
    $ids = @($present | Where-Object { (Get-Prop $_ 'kind' 'files') -eq 'files' } | ForEach-Object { $_.id }) + @($secret | ForEach-Object { $_.id })
    $script:state.SizeJob = Start-Job -ArgumentList (Join-Path $ScriptDir 'MigrationCommon.psm1'), (Join-Path $ScriptDir 'catalog.json'), $ids -ScriptBlock {
        param($mod, $catPath, $ids)
        Import-Module $mod -Force; $cat = Get-MigCatalog $catPath
        foreach ($e in $cat.entries) {
            if ($ids -notcontains $e.id) { continue }
            $bytes = [int64]0
            foreach ($p in @(Get-MigEntryPaths $e)) {
                $x = Expand-MigPath $p; if (-not (Test-Path -LiteralPath $x)) { continue }
                $it = Get-Item -LiteralPath $x -Force
                if ($it.PSIsContainer) { $bytes += (Get-MigDirStats -Path $x -ExcludeDirs @(Get-Prop $e 'excludeDirs' @()) -ExcludeFiles @(Get-Prop $e 'excludeFiles' @()) -IncludeFiles @(Get-Prop $e 'includeFiles' @()) -MaxFileMB 500).Bytes } else { $bytes += $it.Length }
            }
            [pscustomobject]@{ id = $e.id; mb = [math]::Round($bytes / 1MB, 2) }
        }
    }
    $t = New-Object Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromMilliseconds(700)
    $t.Add_Tick({
        $j = $script:state.SizeJob; if (-not $j) { $script:state.Timer.Stop(); return }
        foreach ($r in @(Receive-Job $j -ErrorAction SilentlyContinue)) { if ($script:state.SizeLabels.ContainsKey($r.id)) { $script:state.SizeLabels[$r.id].Text = Format-MB $r.mb } }
        if ($j.State -ne 'Running') { foreach ($r in @(Receive-Job $j -ErrorAction SilentlyContinue)) { if ($script:state.SizeLabels.ContainsKey($r.id)) { $script:state.SizeLabels[$r.id].Text = Format-MB $r.mb } }; Remove-Job $j -Force -ErrorAction SilentlyContinue; $script:state.SizeJob = $null; $script:state.Timer.Stop() }
    })
    $script:state.Timer = $t; $t.Start()
    Set-Footer 'Pack my settings' $true $true 'Nothing is changed on this computer. Close Outlook, your browsers and editors first so their files are not locked.' {
        & $script:refreshOpen
        if ($script:openProcs.Count -gt 0) { $r = [Windows.MessageBox]::Show("Still open: $((($script:openProcs | ForEach-Object { $script:editorMap[$_] } | Sort-Object -Unique) -join ', ')). Anything not yet written to disk by these programs will be missing from the backup. Pack anyway?", 'PC Migration', 'YesNo', 'Warning'); if ($r -ne 'Yes') { return } }
        $ids = @(Get-CheckedIds $script:Page.Content)
        if ($ids.Count -eq 0) { [Windows.MessageBox]::Show('Tick at least one item.', 'PC Migration') | Out-Null; return }
        $secretIds = @($ids | Where-Object { $id = $_; @($script:catalog.entries | Where-Object { $_.id -eq $id -and (Get-Prop $_ 'secret' $false) }).Count -gt 0 })
        $password = $null
        if ($secretIds.Count -gt 0) {
            if (-not $script:pw1.Password) { [Windows.MessageBox]::Show('Enter a password for the keys-and-passwords bundle, or untick those items.', 'PC Migration') | Out-Null; return }
            if ($script:pw1.Password -ne $script:pw2.Password) { [Windows.MessageBox]::Show('The two passwords do not match.', 'PC Migration') | Out-Null; return }
            $password = $script:pw1.Password
        }
        $script:state.SelectedIds = $ids; $script:state.Password = $password
        $script:state.Destination = Join-Path $script:migRoot ('{0}-{1}-{2}' -f $env:COMPUTERNAME, $env:USERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
        # extra entries (discovered folders, folders you added) travel with the backup so the restore knows them
        $extras = @(); foreach ($id in $ids) { if ($script:extraById.ContainsKey($id)) { $extras += $script:extraById[$id] } }
        foreach ($c in $script:customEntries) { if ($extras -notcontains $c) { $extras += $c } }   # keep customs even if unticked, so the next run remembers them
        if ($extras.Count -gt 0) { New-Item -ItemType Directory -Force -Path $script:state.Destination | Out-Null; @{ entries = $extras } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:state.Destination 'extra-entries.json') -Encoding UTF8 }
        $args = @('-Destination', ('"' + $script:state.Destination + '"'), '-Include', ('"' + ($ids -join ',') + '"'))
        if ($secretIds.Count -gt 0) { $args += '-IncludeSecrets' }
        Stop-Background
        Start-Worker 'Export-Profile.ps1' $args $password
        Show-Run 'export'
    } { Stop-Background; Show-Welcome }
}
function Find-Checkboxes { param($Root) $out = @(); $stack = New-Object System.Collections.Stack; $stack.Push($Root)
    while ($stack.Count -gt 0) { $n = $stack.Pop(); if ($n -is [Windows.Controls.CheckBox]) { $out += $n }
        if ($n -is [Windows.Controls.Panel]) { foreach ($c in $n.Children) { $stack.Push($c) } } elseif ($n -is [Windows.Controls.Decorator]) { if ($n.Child) { $stack.Push($n.Child) } } elseif ($n -is [Windows.Controls.ContentControl] -and $n.Content -is [Windows.UIElement]) { $stack.Push($n.Content) } }
    return $out }

function Show-Run { param([string]$Kind)
    $isExport = ($Kind -eq 'export')
    Set-Header $(if ($isExport) { 'Packing your settings...' } else { 'Restoring your settings...' }) 'This takes a few minutes. Browser profiles are the slow part. You can keep using the computer.' $(if ($isExport) { 'Step 3 of 4' } else { 'Step 5 of 6' })
    $root = New-Stack
    $card = New-Card $null $null
    $script:runStatus = New-Text 'Starting...' 15 'SemiBold'; [void]$card.Child.Children.Add($script:runStatus)
    $script:runBar = New-Object Windows.Controls.ProgressBar; $script:runBar.Margin = '0,12,0,6'; $script:runBar.Maximum = 100; [void]$card.Child.Children.Add($script:runBar)
    $script:runDetail = New-Text '' 12 'Normal' '#6B7280'; [void]$card.Child.Children.Add($script:runDetail)
    $script:runNet = New-Text '' 12 'SemiBold' '#047857' '0,6,0,0'; [void]$card.Child.Children.Add($script:runNet)
    [void]$root.Children.Add($card)
    $logCard = New-Card $null $null
    $exp = New-Object Windows.Controls.Expander; $exp.Header = 'Show details'; $exp.IsExpanded = $false; $exp.Foreground = '#6B7280'
    $script:runLog = New-Object Windows.Controls.TextBox; $script:runLog.IsReadOnly = $true; $script:runLog.FontFamily = 'Consolas'; $script:runLog.FontSize = 12; $script:runLog.Height = 300; $script:runLog.VerticalScrollBarVisibility = 'Auto'; $script:runLog.Background = '#F9FAFB'; $script:runLog.BorderThickness = 0; $script:runLog.TextWrapping = 'Wrap'
    $exp.Content = $script:runLog; [void]$logCard.Child.Children.Add($exp); $script:runExpander = $exp
    [void]$root.Children.Add($logCard)
    $script:Page.Content = $root
    $script:runIsExport = $isExport
    $script:runTotal = [math]::Max(1, $script:state.SelectedIds.Count)
    $script:runPhaseText = @{ 'Phase 1' = 'Taking inventory of installed programs and settings...'; 'Phase 2' = 'Looking through your profile folders...'; 'Phase 3' = $(if ($isExport) { 'Packing settings...' } else { 'Restoring environment, drives, printers and extensions...' }) }
    if (-not $isExport) { $script:runPhaseText['Phase 2'] = 'Restoring settings...' ; $script:runPhaseText['Phase 1'] = 'Checking the backup...' }
    $t = New-Object Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromMilliseconds(600)
    $t.Add_Tick({
        $p = $script:state.Proc; $f = $script:state.OutFile
        $lines = @(); if (Test-Path -LiteralPath $f) { $lines = @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue) }
        $txt = ($lines | Where-Object { $_ -match '^\d{4}-' } | ForEach-Object { $_.Substring(20) }) -join "`r`n"
        if ($txt -ne $script:runLog.Text) { $script:runLog.Text = $txt; $script:runLog.ScrollToEnd() }
        $done = @($lines | Where-Object { $_ -match '\[(OK|WARN|ERROR|WAIT)\s*\]\s+(\S+)' -and ($script:state.SelectedIds -contains $matches[2]) }).Count
        $phase = ($lines | Where-Object { $_ -match 'Phase \d' } | Select-Object -Last 1)
        if ($phase -match '(Phase \d)') { $script:runStatus.Text = $script:runPhaseText[$matches[1]] }
        # network + pause state: the script logs PAUSE/RESUME lines; the wizard also watches the adapter itself
        $lastPause = @($lines | Where-Object { $_ -match '\] (PAUSE|RESUME)' } | Select-Object -Last 1)
        $netUp = [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
        if ($lastPause.Count -gt 0 -and "$($lastPause[0])" -match '\] PAUSE') { $script:runNet.Text = 'Paused - waiting for the backup location to come back. It resumes by itself; nothing is lost.'; $script:runNet.Foreground = '#B45309' }
        elseif (-not $netUp) { $script:runNet.Text = $(if ($script:runIsExport) { 'Network is down - packing continues (local OneDrive folder); the upload happens when it is back.' } else { 'Network is down - the restore pauses when it needs a file that is still in the cloud.' }); $script:runNet.Foreground = '#B45309' }
        else { $script:runNet.Text = 'Network: connected'; $script:runNet.Foreground = '#047857' }
        $pct = [math]::Min(95, [int](100 * $done / $script:runTotal)); if ($phase -match 'Phase 3' -or ($phase -match 'Phase 2' -and -not $script:runIsExport)) { $pct = [math]::Max($pct, 10) }
        $script:runBar.Value = $pct; $script:runDetail.Text = "$done of $($script:runTotal) items"
        if ($p.HasExited) {
            $script:state.Timer.Stop(); $script:runBar.Value = 100
            $err = ''; if (Test-Path -LiteralPath ($f + '.err')) { $err = (Get-Content -LiteralPath ($f + '.err') -Raw -ErrorAction SilentlyContinue) }
            $warn = @($lines | Where-Object { $_ -match '\[(WARN|ERROR)\s*\]' -and $_ -notmatch 'Wait for OneDrive' }).Count
            if ($p.ExitCode -ne 0 -or ($err -and $err.Trim())) { $script:runStatus.Text = 'Something went wrong - open the details below.'; $script:runExpander.IsExpanded = $true; if ($err) { $script:runLog.AppendText("`r`n" + $err) } }
            elseif ($warn -gt 0) { $script:runStatus.Text = "Finished. $warn item(s) had a problem (usually a file that was in use) - the next page explains." }
            else { $script:runStatus.Text = 'Finished.' }
            $script:state.Done = $true; $script:NextBtn.IsEnabled = $true
        }
    })
    $script:state.Timer = $t; $script:state.Done = $false; $t.Start()
    Set-Footer 'Continue' $false $false 'Please leave this window open until it finishes.' { Stop-Background; if ($script:runIsExport) { Show-DoneExport } else { Show-DoneImport } } $null
}

function Show-DoneExport {
    $dest = $script:state.Destination
    $m = $null; try { $m = Get-Content -LiteralPath (Join-Path $dest 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    Set-Header 'All packed' "Your settings are in OneDrive. Let OneDrive finish uploading before you use the new computer." 'Step 4 of 4'
    $root = New-Stack
    if ($m) {
        $bytes = [int64]0; foreach ($e in @($m.entries) + @($m.secrets)) { $bytes += [int64]$e.bytes }
        $c = New-Card "$(@($m.entries).Count + @($m.secrets).Count) items packed, $(Format-MB ($bytes / 1MB))" "Folder: $dest"
        [void]$c.Child.Children.Add((New-Button 'Open the folder' 'Secondary' { Start-Process explorer.exe ('"' + $script:state.Destination + '"') }))
        if (Test-Path -LiteralPath (Join-Path $dest 'inventory\browser-extensions.md')) { [void]$c.Child.Children.Add((New-Button 'Browser extensions list' 'Secondary' { Start-Process (Join-Path $script:state.Destination 'inventory\browser-extensions.md') })) }
        [void]$root.Children.Add($c)
        $fails = @(); foreach ($e in @($m.entries)) { if (@($e.failures).Count -gt 0) { $fails += $e.app } }
        $large = @(); foreach ($e in @($m.entries)) { foreach ($f in @($e.largeFilesSkipped)) { $large += $f } }
        if ($fails.Count -gt 0) { $c = New-Card 'Some files were in use' ("These were packed only partly because a program had them open: " + ($fails -join ', ') + ". Close that program and run the wizard again, ticking just those items; the new run is merged into this folder."); $c.Background = '#FFFBEB'; [void]$root.Children.Add($c) }
        if ($large.Count -gt 0) { $c = New-Card "$($large.Count) very large file(s) left out" (($large | Select-Object -First 8) -join "`n"); $c.Background = '#FFFBEB'; [void]$c.Child.Children.Add((New-Text 'Copy them into OneDrive by hand if you need them (PST archives, for example).' 12 'Normal' '#6B7280' '0,6,0,0')); [void]$root.Children.Add($c) }
    } else { $c = New-Card 'Something went wrong' "No manifest was written to $dest. Scroll back through the details, or look in the logs folder there."; $c.Background = '#FEF2F2'; [void]$root.Children.Add($c) }
    $n = New-Card 'Do this next' ''
    foreach ($l in @('1.  Wait for OneDrive to show a green tick on the PCMigration folder (bottom-right OneDrive icon shows progress).', '2.  On the NEW computer, sign in to OneDrive, open the same PCMigration folder in OneDrive\Documents\Claude\WindowsPCMigration (or wherever you keep this wizard) and double-click Start Migration.', '3.  Choose "This is my NEW computer" and follow the steps.')) { [void]$n.Child.Children.Add((New-Text $l 13 'Normal' '#374151' '0,3,0,3')) }
    [void]$root.Children.Add($n)
    $steps = Get-ManualSteps (Join-Path $dest 'report.md')
    if ($steps.Count -gt 0) { $mc = New-Card 'Things only you can do after the restore' 'Windows keeps these encrypted to this computer, so no tool can carry them. The same list is shown again at the end of the restore.'; foreach ($s in ($steps | Select-Object -First 12)) { [void]$mc.Child.Children.Add((New-Text ('-  ' + $s) 12 'Normal' '#374151' '0,2,0,2')) }; [void]$root.Children.Add($mc) }
    $script:Page.Content = $root
    Set-Footer 'Finish' $true $false '' { $script:win.Close() } $null
}

function Show-PickSource {
    Stop-Background
    Set-Header 'Which backup?' 'Backups found in OneDrive\PCMigration. The newest is selected.' 'Step 2 of 6'
    $root = New-Stack
    $exports = @(Get-Exports)
    if ($exports.Count -eq 0) {
        $c = New-Card 'No backup found yet' "Nothing in $($script:migRoot) has a manifest. Either the old computer has not been packed yet, or OneDrive has not finished syncing. Wait for the folder to appear, then press Refresh."; $c.Background = '#FFFBEB'
        [void]$c.Child.Children.Add((New-Button 'Refresh' 'Secondary' { Show-PickSource })); [void]$root.Children.Add($c); $script:Page.Content = $root
        Set-Footer 'Next' $false $true '' $null { Show-Welcome }; return
    }
    $c = New-Card 'Backup to restore' ''
    $combo = New-Object Windows.Controls.ComboBox; foreach ($e in $exports) { [void]$combo.Items.Add($e.Label) }; $combo.SelectedIndex = 0; [void]$c.Child.Children.Add($combo)
    $script:srcCombo = $combo; $script:srcExports = $exports
    $script:srcInfo = New-Text '' 12 'Normal' '#6B7280' '0,8,0,0'; [void]$c.Child.Children.Add($script:srcInfo)
    $upd = { $e = $script:srcExports[$script:srcCombo.SelectedIndex]
        $ph = @(Get-ChildItem -LiteralPath $e.Path -Recurse -File -ErrorAction SilentlyContinue | Where-Object { ([int]$_.Attributes -band 0x400000) -ne 0 }).Count
        $same = if ($e.Computer -eq $env:COMPUTERNAME) { ' Note: this backup was made on THIS computer.' } else { '' }
        $bv = "$(Get-Prop $e.Manifest 'kitVersion' 'unknown')"
        $same += " Made with kit $bv." + $(if ((Compare-MigVersion $bv $script:kitVersion) -gt 0) { " THIS WIZARD IS OLDER ($script:kitVersion) - get the newer PCMigration exe before restoring." } else { '' })
        $script:srcInfo.Text = "$($e.Packages) items, $($e.Secrets) secret bundle(s), made by $($e.User) on $($e.Computer).$same" + $(if ($ph -gt 0) { " $ph file(s) are not downloaded yet - press 'Download everything now' and wait for the green tick before continuing." } else { ' All files are available locally.' })
        $script:srcPlaceholders = $ph }
    $combo.Add_SelectionChanged($upd); & $upd
    [void]$c.Child.Children.Add((New-Button 'Download everything now' 'Secondary' { $e = $script:srcExports[$script:srcCombo.SelectedIndex]; & attrib.exe +P -U ($e.Path) /S /D | Out-Null; & attrib.exe +P -U (Join-Path $e.Path '*') /S /D | Out-Null; [Windows.MessageBox]::Show('OneDrive is now downloading the backup. Watch the OneDrive icon; press Next when it shows the green tick.', 'PC Migration') | Out-Null }))
    [void]$root.Children.Add($c)
    $script:Page.Content = $root
    Set-Footer 'Next' $true $true '' { $e = $script:srcExports[$script:srcCombo.SelectedIndex]; $script:state.Source = $e.Path; $script:state.Manifest = $e.Manifest; $script:catalog = Merge-MigExtraEntries -Catalog $script:catalog -Path (Join-Path $e.Path 'extra-entries.json'); Show-Software } { Show-Welcome }
}

function Show-Software {
    Stop-Background
    Set-Header 'What to install on this PC' 'Everything the old computer had that this one does not. Install from the portal or the links, then press Installed - or Skip what you no longer need. Items you skip keep their settings out of the restore; the list remembers itself if you close the wizard.' 'Step 3 of 6'
    $root = New-Stack
    $wait = New-Card 'Checking this computer...' 'Comparing programs, extensions, developer tools and packages with the backup. A few seconds.'; [void]$root.Children.Add($wait); $script:Page.Content = $root
    Set-Footer 'Next' $false $true '' { Show-ImportSelect } { Show-PickSource }
    Start-Worker 'Compare-Software.ps1' @('-Source', ('"' + $script:state.Source + '"'))
    $t = New-Object Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromMilliseconds(700)
    $t.Add_Tick({ if (-not $script:state.Proc.HasExited) { return }; $script:state.Timer.Stop(); Show-Checklist })
    $script:state.Timer = $t; $t.Start()
}

$script:kindTitles = [ordered]@{ program = 'Programs (company portal or installer)'; store = 'Microsoft Store apps'; portable = 'Programs that had no installer'; tool = 'Developer tools (Java, Node, Python, .NET, Git...)'; 'vscode-ext' = 'VS Code extensions'; 'browser-ext' = 'Browser extensions'; npm = 'npm global packages'; pip = 'Python packages (pip --user)'; 'dotnet-tool' = '.NET global tools'; 'ps-module' = 'PowerShell modules' }

function Show-Checklist {
    $root = New-Stack
    $src = $script:state.Source
    $itemsFile = Join-Path $src 'install-items.json'
    if (-not (Test-Path -LiteralPath $itemsFile)) { $c = New-Card 'Comparison failed' (Get-Content -LiteralPath ($script:state.OutFile + '.err') -Raw -ErrorAction SilentlyContinue); $c.Background = '#FEF2F2'; [void]$root.Children.Add($c); $script:Page.Content = $root; $script:NextBtn.IsEnabled = $true; return }
    $script:ckItems = @((Get-Content -LiteralPath $itemsFile -Raw -Encoding UTF8 | ConvertFrom-Json).items)
    $script:ckState = Get-MigInstallState $src
    # detected now -> installed (unless the user skipped it); first visit -> pending
    $changed = $false
    foreach ($it in $script:ckItems) {
        $k = "$($it.key)"; $cur = $script:ckState[$k]
        if ($it.installed -and (-not $cur -or $cur.status -ne 'installed')) { $script:ckState[$k] = @{ status = 'installed'; at = (Get-Date).ToString('o'); by = 'auto' }; $changed = $true }
        elseif (-not $cur) { $script:ckState[$k] = @{ status = 'pending'; at = ''; by = '' } ; $changed = $true }
    }
    if ($changed) { Save-MigInstallState $src $script:ckState }
    $nI = @($script:ckState.Values | Where-Object { $_.status -eq 'installed' }).Count; $nS = @($script:ckState.Values | Where-Object { $_.status -eq 'skipped' }).Count; $nP = @($script:ckItems).Count - $nI - $nS
    $sum = New-Card "$nI installed, $nS skipped, $nP still to do" $(if ($nP -eq 0) { 'Nothing left on the list. Press Next to restore the settings.' } else { 'Install what you need, then press "Check again" - installed programs are recognised automatically. You can go on to the restore at any time and come back later.' })
    $tb = New-Stack 'Horizontal'
    [void]$tb.Children.Add((New-Button 'Check again' 'Secondary' { Show-Software }))
    [void]$tb.Children.Add((New-Button 'Open install-list.md' 'Secondary' { Start-Process (Join-Path $script:state.Source 'install-list.md') }))
    [void]$tb.Children.Add((New-Button 'Copy the to-do list' 'Secondary' { $lines = @(); foreach ($it in $script:ckItems) { if ($script:ckState["$($it.key)"].status -eq 'pending') { $lines += "$($it.kind): $($it.name) $(Get-Prop $it 'oldVersion' '') $($it.detail)" } }; [Windows.Clipboard]::SetText(($lines -join "`r`n")); [Windows.MessageBox]::Show("Copied $($lines.Count) items.", 'PC Migration') | Out-Null }))
    [void]$sum.Child.Children.Add($tb); [void]$root.Children.Add($sum)
    $script:onItemClick = {
        param($b, $e)
        $tag = $b.Tag; $k = $tag.Key; $it = $tag.Item
        switch ($tag.Action) {
            'installed' { $script:ckState[$k] = @{ status = 'installed'; at = (Get-Date).ToString('o'); by = 'user' } }
            'skipped'   { $script:ckState[$k] = @{ status = 'skipped'; at = (Get-Date).ToString('o'); by = 'user' } }
            'undo'      { $script:ckState[$k] = @{ status = 'pending'; at = ''; by = '' } }
            'open'      { try { Start-Process "$($it.link)" } catch { [Windows.MessageBox]::Show("Could not open $($it.link)", 'PC Migration') | Out-Null }; return }
            'install'   { Start-Process powershell.exe -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "$($it.command)"); return }
            'copy'      { [Windows.Clipboard]::SetText("$($it.name)"); return }
        }
        Save-MigInstallState $script:state.Source $script:ckState
        Show-Checklist
    }
    foreach ($kind in $script:kindTitles.Keys) {
        $group = @($script:ckItems | Where-Object { "$($_.kind)" -eq $kind })
        if ($group.Count -eq 0) { continue }
        $todo = @($group | Where-Object { $script:ckState["$($_.key)"].status -eq 'pending' })
        $doneG = @($group | Where-Object { $script:ckState["$($_.key)"].status -ne 'pending' })
        $card = New-Card ("{0}  -  {1} of {2} done" -f $script:kindTitles[$kind], ($group.Count - $todo.Count), $group.Count) ''
        $withCmd = @($todo | Where-Object { "$($_.command)" })
        if ($withCmd.Count -gt 1) {
            $allBtn = New-Button "Install all $($withCmd.Count) missing now (opens a PowerShell window)" 'Secondary' { }
            $allBtn.Tag = @{ Cmds = @($withCmd | ForEach-Object { "$($_.command)" }) }
            $allBtn.Add_Click({ param($b, $e) Start-Process powershell.exe -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', (($b.Tag.Cmds + 'Write-Host ""; Write-Host "Done - press Check again in the wizard" -ForegroundColor Green') -join '; ')) })
            [void]$card.Child.Children.Add($allBtn)
        }
        foreach ($it in $todo) { [void]$card.Child.Children.Add((New-ChecklistRow $it 'pending')) }
        if ($doneG.Count -gt 0) {
            $exp = New-Object Windows.Controls.Expander; $exp.Header = "$($doneG.Count) installed or skipped"; $exp.IsExpanded = ($todo.Count -eq 0 -and $doneG.Count -le 8); $exp.Foreground = '#6B7280'; $exp.Margin = '0,6,0,0'
            $sp = New-Stack; foreach ($it in $doneG) { [void]$sp.Children.Add((New-ChecklistRow $it $script:ckState["$($it.key)"].status)) }; $exp.Content = $sp
            [void]$card.Child.Children.Add($exp)
        }
        [void]$root.Children.Add($card)
    }
    $script:Page.Content = $root; $script:NextBtn.IsEnabled = $true
    $script:FooterNote.Text = 'Press Next to restore settings now; items still to do can be installed later - run the wizard again and it continues here.'
}

function New-ChecklistRow { param($Item, [string]$Status)
    $g = New-Object Windows.Controls.Grid; $g.Margin = '0,4,0,4'
    $g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition)); $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = [Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($cd)
    $left = New-Stack
    $color = switch ($Status) { 'installed' { '#047857' } 'skipped' { '#6B7280' } default { '#111827' } }
    $mark = switch ($Status) { 'installed' { 'installed  ' } 'skipped' { 'skipped  ' } default { '' } }
    [void]$left.Children.Add((New-Text ("{0}{1}" -f $mark, $Item.name) 14 $(if ($Status -eq 'pending') { 'SemiBold' } else { 'Normal' }) $color))
    $ov = "$(Get-Prop $Item 'oldVersion' '')"; $hv = "$(Get-Prop $Item 'hereVersion' '')"
    $ver = $(if ($ov -and $hv) { $(if ($ov -eq $hv) { "version $ov (same here)" } else { "old PC $ov  ->  here $hv" }) } elseif ($ov) { "old PC $ov" + $(if ($Status -eq 'installed') { ' (version here not detected)' } else { '' }) } elseif ($hv) { "here $hv" } else { '' })
    $sub = @($ver, "$($Item.detail)", "$($Item.hint)") | Where-Object { $_ }
    if ($sub.Count -gt 0) { [void]$left.Children.Add((New-Text ($sub -join '   -   ') 12 'Normal' '#6B7280')) }
    $right = New-Stack 'Horizontal'
    $mk = { param($txt, $action) $b = New-Button $txt 'Secondary' { }; $b.Padding = '10,5'; $b.Margin = '6,0,0,0'; $b.FontSize = 12; $b.Tag = @{ Key = "$($Item.key)"; Item = $Item; Action = $action }; $b.Add_Click($script:onItemClick); $b }
    if ($Status -eq 'pending') {
        if ("$($Item.link)") { [void]$right.Children.Add((& $mk 'Open' 'open')) }
        if ("$($Item.command)") { [void]$right.Children.Add((& $mk 'Install now' 'install')) }
        if ("$($Item.kind)" -in 'program', 'store', 'portable', 'tool') { [void]$right.Children.Add((& $mk 'Copy name' 'copy')) }
        [void]$right.Children.Add((& $mk 'Installed' 'installed')); [void]$right.Children.Add((& $mk 'Skip' 'skipped'))
    } else { [void]$right.Children.Add((& $mk 'Undo' 'undo')) }
    [Windows.Controls.Grid]::SetColumn($left, 0); [Windows.Controls.Grid]::SetColumn($right, 1)
    [void]$g.Children.Add($left); [void]$g.Children.Add($right)
    return $g
}

function Show-ImportSelect {
    Stop-Background
    $m = $script:state.Manifest; $script:impManifest = $m
    $byId = @{}; foreach ($e in $script:catalog.entries) { $byId[$e.id] = $e }
    # previous runs on this computer + which programs exist now
    $prev = @{}; $sp = Join-Path $script:state.Source "restore-state-$env:COMPUTERNAME.json"
    if (Test-Path -LiteralPath $sp) { try { $sj = Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $sj.entries.PSObject.Properties) { $prev[$p.Name] = $p.Value } } catch { } }
    $script:rowState = @{}; $nReady = 0; $nWait = 0; $nDone = 0; $script:forceIds = @()
    # the install list: programs you skipped keep their settings out; programs you marked installed by hand are restored anyway
    $ck = Get-MigInstallState $script:state.Source
    $ckItems = @(); $cif = Join-Path $script:state.Source 'install-items.json'; if (Test-Path -LiteralPath $cif) { try { $ckItems = @((Get-Content -LiteralPath $cif -Raw -Encoding UTF8 | ConvertFrom-Json).items | Where-Object { "$($_.kind)" -in 'program', 'store', 'portable', 'tool' }) } catch { } }
    $skippedNames = @($ckItems | Where-Object { $ck["$($_.key)"] -and $ck["$($_.key)"].status -eq 'skipped' } | ForEach-Object { "$($_.name)" })
    $manualNames = @($ckItems | Where-Object { $ck["$($_.key)"] -and $ck["$($_.key)"].status -eq 'installed' -and $ck["$($_.key)"].by -eq 'user' } | ForEach-Object { "$($_.name)" })
    $matchProg = { param($entry, $names) foreach ($c in @(Get-Prop $entry 'appCheck' @())) { if ("$c" -like 'uninstall:*') { $re = "$c".Substring(10); foreach ($n in $names) { if ($n -match $re) { return $n } } } }; $an = "$(Get-Prop $entry 'appName' '')"; if ($an) { foreach ($n in $names) { if ($n -match [regex]::Escape($an) -or $an -match [regex]::Escape($n)) { return $n } } }; return $null }
    foreach ($pk in @($m.entries) + @($m.secrets)) {
        $id = "$($pk.id)"; $e = $byId[$id]; $inst = $(if ($e) { Test-MigAppInstalled $e } else { $null }); $pv = $prev[$id]
        $skippedBy = $(if ($e) { & $matchProg $e $skippedNames } else { $null }); $manualBy = $(if ($e -and $inst -eq $false) { & $matchProg $e $manualNames } else { $null })
        if ($skippedBy -and -not ($pv -and "$($pv.status)" -eq 'restored')) { $script:rowState[$id] = @{ Enabled = $true; Checked = $false; Badge = "You skipped '$skippedBy' on the install list - left out. Tick to restore its settings anyway."; BadgeColor = '#6B7280' }; $nDone++ }
        elseif ($manualBy) { $script:forceIds += $id; $script:rowState[$id] = @{ Enabled = $true; Checked = $true; Badge = "You marked '$manualBy' as installed - restored even though it was not detected."; BadgeColor = '#047857' }; $nReady++ }
        elseif ($inst -eq $false) { $script:rowState[$id] = @{ Enabled = $false; Checked = $false; Badge = "Waiting for $(Get-MigAppName $e) to be installed. Install it (or mark it installed on the install list), then run this wizard again."; BadgeColor = '#B45309' }; $nWait++ }
        elseif ($pv -and "$($pv.status)" -eq 'restored') { $script:rowState[$id] = @{ Enabled = $true; Checked = $false; Badge = "Restored earlier ($(([datetime]$pv.at).ToString('dd MMM HH:mm'))). Tick to restore again."; BadgeColor = '#047857' }; $nDone++ }
        elseif ($pv -and "$($pv.status)" -eq 'deferred') { $script:rowState[$id] = @{ Enabled = $true; Checked = $true; Badge = "$(Get-MigAppName $e) is installed now - ready to restore."; BadgeColor = '#047857' }; $nReady++ }
        elseif ($e -and "$(Get-Prop $e 'dynamic' '')" -eq 'hkcu-vendors') {
            $vend = @($pk.items | ForEach-Object { "$($_.vendor)" } | Where-Object { $_ })
            $ready = @($vend | Where-Object { Test-MigVendorInstalled $_ }); $wait = @($vend | Where-Object { $ready -notcontains $_ })
            $script:rowState[$id] = @{ Enabled = $true; Checked = ($ready.Count -gt 0); Badge = "Ready now: $(if ($ready.Count) { $ready -join ', ' } else { 'none' }). Waiting for a program: $(if ($wait.Count) { $wait -join ', ' } else { 'none' }) - those are picked up on a later run."; BadgeColor = '#047857' }; $nReady++
        }
        else { $script:rowState[$id] = @{ Enabled = $true; Checked = (-not (Get-Prop $e 'defaultOff' $false)); Badge = ''; BadgeColor = '' }; $nReady++ }
    }
    Set-Header 'What do you want to restore?' "From the backup made on $($m.computer). $nReady ready, $nDone restored earlier, $nWait waiting for a program to be installed. Anything already set up here the way you like can be unticked." 'Step 4 of 6'
    $root = New-Stack
    $tools = New-Stack 'Horizontal'
    [void]$tools.Children.Add((New-Button 'Select all' 'Secondary' { foreach ($cb in (Find-Checkboxes $script:Page.Content)) { if ($cb.Tag -is [hashtable] -or $cb.FontSize -eq 16) { $cb.IsChecked = $true } } }))
    [void]$tools.Children.Add((New-Button 'Select none' 'Secondary' { foreach ($cb in (Find-Checkboxes $script:Page.Content)) { if ($cb.Tag -is [hashtable] -or $cb.FontSize -eq 16) { $cb.IsChecked = $false } } }))
    [void]$root.Children.Add($tools)
    # running apps
    $script:procMap = @{ 'Notepad' = 'win-notepad-tabs'; 'msedge' = 'browser-edge'; 'chrome' = 'browser-chrome'; 'firefox' = 'browser-firefox'; 'opera' = 'browser-opera'; 'Code' = 'dev-vscode'; 'Cursor' = 'dev-cursor'; 'notepad++' = 'dev-notepadpp'; 'OUTLOOK' = 'office-'; 'EXCEL' = 'office-'; 'WINWORD' = 'office-'; 'POWERPNT' = 'office-'; 'ONENOTE' = 'office-'; 'putty' = 'tools-putty'; 'WinSCP' = 'tools-winscp'; 'MobaXterm' = 'tools-mobaxterm'; 'SecureCRT' = 'tools-securecrt'; 'Xshell' = 'tools-xshell'; 'WindowsTerminal' = 'dev-windows-terminal'; 'dbeaver' = 'data-dbeaver'; 'Ssms' = 'data-ssms'; 'idea64' = 'dev-jetbrains'; 'pycharm64' = 'dev-jetbrains'; 'devenv' = 'dev-visualstudio'; 'PowerToys' = 'tools-powertoys'; 'Postman' = 'data-postman'; 'PBIDesktop' = 'data-power-bi'; 'KeePass' = 'tools-keepass'; 'claude' = 'dev-claude-desktop' }
    $script:runningCard = New-Card 'Some programs must be closed first' ''; $script:runningCard.Background = '#FFFBEB'
    $script:runningText = New-Text '' 13 'Normal' '#374151'; [void]$script:runningCard.Child.Children.Add($script:runningText)
    [void]$script:runningCard.Child.Children.Add((New-Button 'Close them for me' 'Secondary' { foreach ($pn in $script:runningNames) { Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() } }; Start-Sleep -Seconds 2; & $script:refreshRunning }))
    $script:refreshRunning = {
        $names = @(); foreach ($pn in $script:procMap.Keys) { if (Get-Process -Name $pn -ErrorAction SilentlyContinue) { if (@($script:impManifest.entries | Where-Object { $_.id -like ($script:procMap[$pn] + '*') }).Count -gt 0) { $names += $pn } } }
        $script:runningNames = $names
        if ($names.Count -gt 0) { $script:runningText.Text = 'Open right now: ' + ($names -join ', ') + '. Their settings are restored only after they are closed (save your work first).'; $script:runningCard.Visibility = 'Visible' } else { $script:runningCard.Visibility = 'Collapsed' }
    }
    & $script:refreshRunning
    [void]$root.Children.Add($script:runningCard)
    foreach ($cat in $catOrder) {
        if (-not $catTitles.ContainsKey($cat)) { continue }
        $rows = @($m.entries | Where-Object { "$($_.category)" -eq $cat } | ForEach-Object { $rs = $script:rowState["$($_.id)"]; @{ Id = "$($_.id)"; Name = "$($_.app)"; Summary = $(if ($byId.ContainsKey("$($_.id)")) { Get-Prop $byId["$($_.id)"] 'summary' '' } else { '' }); Note = $(if ($byId.ContainsKey("$($_.id)")) { Get-Prop $byId["$($_.id)"] 'notes' '' } else { '' }); SizeMB = ([double]$_.bytes / 1MB); Checked = $rs.Checked; Enabled = $rs.Enabled; Badge = $rs.Badge; BadgeColor = $rs.BadgeColor } })
        if ($rows.Count -eq 0) { continue }
        [void]$root.Children.Add((New-SelectionCard $catTitles[$cat] $rows))
    }
    $script:ipw = $null
    if (@($m.secrets).Count -gt 0) {
        $rows = @($m.secrets | ForEach-Object { $rs = $script:rowState["$($_.id)"]; @{ Id = "$($_.id)"; Name = "$($_.app)"; Summary = $(if ($byId.ContainsKey("$($_.id)")) { Get-Prop $byId["$($_.id)"] 'summary' '' } else { '' }); Note = ''; SizeMB = ([double]$_.bytes / 1MB); Checked = $false; Enabled = $rs.Enabled; Badge = $rs.Badge; BadgeColor = $rs.BadgeColor } })
        $sc = New-SelectionCard 'Keys and passwords' $rows $(if ($m.secretsEncrypted) { 'Encrypted on the old computer. Enter the password you chose there.' } else { 'These were stored unencrypted.' })
        if ($m.secretsEncrypted) { $pw = New-Stack 'Horizontal'; $pw.Margin = '24,8,0,0'; [void]$pw.Children.Add((New-Text 'Password:' 13 'Normal' '#374151' '0,8,10,0')); $script:ipw = New-Object Windows.Controls.PasswordBox; [void]$pw.Children.Add($script:ipw); [void]$sc.Child.Children.Add($pw) }
        [void]$root.Children.Add($sc)
    }
    $script:forceCb = New-Object Windows.Controls.CheckBox; $script:forceCb.Margin = '0,6,0,0'; [Windows.Automation.AutomationProperties]::SetName($script:forceCb, 'restore-anyway')
    $fcInner = New-Stack; [void]$fcInner.Children.Add((New-Text 'Also restore settings whose program is not installed yet' 14 'Normal')); [void]$fcInner.Children.Add((New-Text 'Normally those wait for the next run. Use this for programs that never appear in Apps and Features (portable tools), or when you simply want everything now.' 12 'Normal' '#6B7280'))
    $script:forceCb.Content = $fcInner
    $fcCard = New-Card $null $null; [void]$fcCard.Child.Children.Add($script:forceCb); [void]$root.Children.Add($fcCard)
    $script:Page.Content = $root
    Set-Footer 'Restore my settings' $true $true 'Anything replaced is backed up first under AppData\Local\PCMigration-backup.' {
        & $script:refreshRunning
        $ids = @(Get-CheckedIds $script:Page.Content)
        if ($ids.Count -eq 0) { [Windows.MessageBox]::Show('Tick at least one item.', 'PC Migration') | Out-Null; return }
        if ($script:runningNames.Count -gt 0) {
            $blocked = @(); foreach ($pn in $script:runningNames) { foreach ($i in $ids) { if ($i -like ($script:procMap[$pn] + '*')) { $blocked += $i } } }
            if ($blocked.Count -gt 0) { $r = [Windows.MessageBox]::Show("Still open: $($script:runningNames -join ', '). Continue and skip their settings for now?", 'PC Migration', 'YesNo', 'Warning'); if ($r -ne 'Yes') { return }; $ids = @($ids | Where-Object { $blocked -notcontains $_ }) }
        }
        $secretIds = @($ids | Where-Object { $id = $_; @($script:impManifest.secrets | Where-Object { "$($_.id)" -eq $id }).Count -gt 0 })
        $password = $null
        if ($secretIds.Count -gt 0 -and $script:impManifest.secretsEncrypted) { if (-not $script:ipw.Password) { [Windows.MessageBox]::Show('Enter the password of the keys-and-passwords bundle, or untick those items.', 'PC Migration') | Out-Null; return }; $password = $script:ipw.Password }
        $script:state.SelectedIds = $ids
        $args = @('-Source', ('"' + $script:state.Source + '"'), '-Include', ('"' + ($ids -join ',') + '"'), '-Force')
        if ($secretIds.Count -gt 0) { $args += '-IncludeSecrets' }
        if ($script:forceCb.IsChecked) { $args += '-RestoreEvenIfMissing' }
        $forced = @($script:forceIds | Where-Object { $ids -contains $_ }); if ($forced.Count -gt 0) { $args += @('-ForceIds', ('"' + ($forced -join ',') + '"')) }
        Stop-Background
        Start-Worker 'Import-Profile.ps1' $args $password
        Show-Run 'import'
    } { Show-Software }
}

function Show-DoneImport {
    $src = $script:state.Source
    Set-Header 'Restore finished' 'Sign out and back in so Windows picks up the desktop, taskbar and Explorer settings.' 'Step 6 of 6'
    $root = New-Stack
    $rep = Get-ChildItem -LiteralPath $src -Filter "import-$env:COMPUTERNAME-*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; $script:impReport = $rep
    $okN = 0; $badN = 0
    if ($rep) { foreach ($l in (Get-Content -LiteralPath $rep.FullName -Encoding UTF8)) { if ($l -match '^\|\s*`[^`]+`\s*\|\s*(\w[\w-]*)\s*\|') { if ($matches[1] -eq 'ok') { $okN++ } elseif ($matches[1] -in 'partial', 'failed', 'missing') { $badN++ } } } }
    $c = New-Card "$okN item(s) restored$(if ($badN) { ", $badN with problems" })" $(if ($badN) { 'Problems are usually a file still open in a program. Close it and run the wizard again for just that item.' } else { '' })
    if ($rep) { [void]$c.Child.Children.Add((New-Button 'Open the report' 'Secondary' { Start-Process $script:impReport.FullName })) }
    if (Test-Path -LiteralPath (Join-Path $src 'inventory\browser-extensions.md')) { [void]$c.Child.Children.Add((New-Button 'Browser extensions list (with install links)' 'Secondary' { Start-Process (Join-Path $script:state.Source 'inventory\browser-extensions.md') })) }
    [void]$c.Child.Children.Add((New-Button 'Back to the install list' 'Secondary' { Show-Software }))
    [void]$c.Child.Children.Add((New-Button 'Sign out now' 'Primary' { $r = [Windows.MessageBox]::Show('Save your work in other programs, then press OK to sign out.', 'PC Migration', 'OKCancel', 'Question'); if ($r -eq 'OK') { & shutdown.exe /l } }))
    [void]$root.Children.Add($c)
    $waiting = @()
    if ($rep) { foreach ($l in (Get-Content -LiteralPath $rep.FullName -Encoding UTF8)) { if ($l -match '^\|\s*`([^`]+)`\s*\|\s*deferred\s*\|\s*waiting for (.+?) to be installed') { $waiting += $matches[2] } } }
    if ($waiting.Count -gt 0) {
        $wc = New-Card "Install these programs, then run this wizard again ($(@($waiting | Sort-Object -Unique).Count))" 'Their settings are in the backup but the program is not on this computer yet. The wizard remembers them and offers them again once the program exists.'; $wc.Background = '#FFFBEB'
        foreach ($w in ($waiting | Sort-Object -Unique)) { [void]$wc.Child.Children.Add((New-Text ('-  ' + $w) 13 'Normal' '#374151' '0,2,0,2')) }
        [void]$root.Children.Add($wc)
    }
    $steps = Get-ManualSteps (Join-Path $src 'report.md')
    if ($steps.Count -gt 0) { $mc = New-Card 'Things only you can do' 'Windows keeps these encrypted to the old computer, so no tool can carry them.'; foreach ($s in $steps) { [void]$mc.Child.Children.Add((New-Text ('-  ' + $s) 12 'Normal' '#374151' '0,2,0,2')) }; [void]$root.Children.Add($mc) }
    $n = New-Card 'Later' ''
    foreach ($l in @('-  Installed more programs from the portal? Run the wizard again and tick just their settings.', '-  Everything replaced by the restore was backed up to AppData\Local\PCMigration-backup, in case you want something back.')) { [void]$n.Child.Children.Add((New-Text $l 13 'Normal' '#374151' '0,3,0,3')) }
    [void]$root.Children.Add($n)
    $script:Page.Content = $root
    Set-Footer 'Finish' $true $false '' { $script:win.Close() } $null
}

# ------------------------------------------------------------------ run
$script:win.Add_Closing({ param($s, $e) if ($script:state.Proc -and -not $script:state.Proc.HasExited -and -not $script:state.Done) { $r = [Windows.MessageBox]::Show('Work is still running. Close anyway?', 'PC Migration', 'YesNo', 'Warning'); if ($r -ne 'Yes') { $e.Cancel = $true; return } }; Stop-Background })
Show-Welcome
[void]$script:win.ShowDialog()
