using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Media;

namespace PCMigration.Pages
{
    public class BackupRow : Observable
    {
        public BackupInfo Info { get; set; }
        private bool _sel; public bool IsSelected { get { return _sel; } set { Set(ref _sel, value); } }
        public bool HasPlaceholders { get { return Info.Placeholders > 0; } }
        public List<Badge> Badges { get; set; }
    }
    public class Badge { public string Text { get; set; } public Brush Bg { get; set; } public Brush Fg { get; set; } }

    /// <summary>Import step 2: which backup to restore from.</summary>
    public partial class BackupPage : AppPage
    {
        public override string StepKey { get { return "backup"; } }
        private List<BackupRow> _rows = new List<BackupRow>();
        public BackupPage() { InitializeComponent(); EmptyBar.ActionClick += (s, e) => Load(); ErrorBar.ActionClick += (s, e) => Load(); }

        public override void OnShown()
        {
            Window.SetHeader("Which backup?", "Backups found in the backup location. The newest one made on another computer is selected.");
            Window.SetFooter("Next", false, true, "", Next, () => Window.GoToStep("start"));
            Load();
        }
        public override void OnRootChanged() { Load(); }
        private void Refresh_Click(object sender, RoutedEventArgs e) { Load(); }

        private async void Load()
        {
            LoadingBar.Visibility = Visibility.Visible; EmptyBar.Visibility = Visibility.Collapsed; ErrorBar.Visibility = Visibility.Collapsed; List.ItemsSource = null; Window.SetNextEnabled(false);
            try
            {
                var r = await Engine.Probe("backups");
                var infos = Json.Arr(r, "backups").Select(BackupInfo.From).ToList();
                LoadingBar.Visibility = Visibility.Collapsed;
                if (infos.Count == 0)
                {
                    EmptyBar.Visibility = Visibility.Visible;
                    EmptyBar.Message = "Nothing in " + Session.Env.BackupRoot + " has a manifest. Either the old computer has not been packed yet, or OneDrive has not finished syncing. Wait for the folder to appear, then press Refresh - or change the backup location (bottom left).";
                    return;
                }
                _rows = infos.Select(i => new BackupRow { Info = i, Badges = BadgesFor(i) }).ToList();
                var pick = _rows.FirstOrDefault(x => Session.Backup != null && x.Info.Path == Session.Backup.Path) ?? _rows.FirstOrDefault(x => x.Info.InProgress && !x.Info.MadeHere) ?? _rows.FirstOrDefault(x => !x.Info.MadeHere) ?? _rows[0];
                pick.IsSelected = true;
                foreach (var row in _rows) row.PropertyChanged += (s, e) => Window.SetNextEnabled(_rows.Any(x => x.IsSelected));
                List.ItemsSource = _rows; Window.SetNextEnabled(true);
            }
            catch (EngineException ex) { LoadingBar.Visibility = Visibility.Collapsed; ErrorBar.Visibility = Visibility.Visible; ErrorBar.Title = ex.Message; ErrorBar.Message = ex.Detail; }
        }
        private List<Badge> BadgesFor(BackupInfo i)
        {
            var b = new List<Badge>();
            if (i.InProgress) b.Add(new Badge { Text = "Restore in progress on this PC: " + i.Restored + " restored, " + i.Deferred + " waiting", Bg = Theme.Brush("StatusSuccessBg"), Fg = Theme.Brush("StatusSuccessFg") });
            if (i.NewerThanThisKit) b.Add(new Badge { Text = "Made with a newer version (" + i.KitVersion + ") - get the newer PC Migration before restoring", Bg = Theme.Brush("StatusCriticalBg"), Fg = Theme.Brush("StatusCriticalFg") });
            else if (!string.IsNullOrEmpty(i.KitVersion) && i.KitVersion != Kit.Version) b.Add(new Badge { Text = "Made with version " + i.KitVersion + " - this app is " + Kit.Version, Bg = Theme.Brush("StatusCautionBg"), Fg = Theme.Brush("StatusCautionFg") });
            else b.Add(new Badge { Text = "Made with version " + (string.IsNullOrEmpty(i.KitVersion) ? "unknown" : i.KitVersion), Bg = Theme.Brush("StatusInfoBg"), Fg = Theme.Brush("StatusInfoFg") });
            if (i.Placeholders > 0) b.Add(new Badge { Text = Fmt.Plural(i.Placeholders, "file") + " not downloaded yet", Bg = Theme.Brush("StatusCautionBg"), Fg = Theme.Brush("StatusCautionFg") });
            else b.Add(new Badge { Text = "All files are on this computer", Bg = Theme.Brush("StatusSuccessBg"), Fg = Theme.Brush("StatusSuccessFg") });
            if (i.Secrets > 0) b.Add(new Badge { Text = Fmt.Plural(i.Secrets, "encrypted bundle"), Bg = Theme.Brush("StatusInfoBg"), Fg = Theme.Brush("StatusInfoFg") });
            if (i.MadeHere) b.Add(new Badge { Text = "Made on this computer", Bg = Theme.Brush("StatusCautionBg"), Fg = Theme.Brush("StatusCautionFg") });
            return b;
        }
        private async void Download_Click(object sender, RoutedEventArgs e)
        {
            var row = (BackupRow)((FrameworkElement)sender).Tag;
            try
            {
                Process.Start(new ProcessStartInfo("attrib.exe", "+P -U \"" + row.Info.Path + "\" /S /D") { CreateNoWindow = true, UseShellExecute = false }).WaitForExit();
                Process.Start(new ProcessStartInfo("attrib.exe", "+P -U \"" + row.Info.Path + "\\*\" /S /D") { CreateNoWindow = true, UseShellExecute = false }).WaitForExit();
            }
            catch { }
            await Window.Dialog("Downloading", "OneDrive is now downloading the whole backup. Watch the OneDrive icon; press Refresh here when it shows the green tick.", "OK", null);
        }
        private void OpenFolder_Click(object sender, RoutedEventArgs e) { Shell.OpenFolder(((BackupRow)((FrameworkElement)sender).Tag).Info.Path); }
        private async void Next()
        {
            var row = _rows.FirstOrDefault(x => x.IsSelected); if (row == null) return;
            if (row.Info.NewerThanThisKit && !await Window.Dialog("Backup from a newer version", "This backup was made with PC Migration " + row.Info.KitVersion + "; this is " + Kit.Version + ". Newer entries may be skipped or restored wrongly. Get the newer PC Migration before restoring. Continue anyway?", "Continue", "Go back")) return;
            if (!row.Info.NewerThanThisKit && row.Info.KitVersion != Kit.Version && !await Window.Dialog("Backup from a different version", "This backup was made with PC Migration " + (string.IsNullOrEmpty(row.Info.KitVersion) ? "an unknown version" : row.Info.KitVersion) + "; this is " + Kit.Version + ". Restoring across versions works, but entries that changed between them may land differently - the report lists every item. Best use the same version on both computers.", "Continue", "Go back")) return;
            if (Session.Backup == null || Session.Backup.Path != row.Info.Path) { Session.InstallItems = null; Session.ImportGroups = null; }
            Session.Backup = row.Info;
            Window.GoToStep("install");
        }
    }
}
