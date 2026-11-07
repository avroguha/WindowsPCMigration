using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;

namespace PCMigration.Pages
{
    /// <summary>The result: what happened, what to do next, what only the user can do.</summary>
    public partial class DonePage : AppPage
    {
        public override string StepKey { get { return "done"; } }
        private string _folder, _report, _ext;
        public DonePage() { InitializeComponent(); }

        public override void OnShown()
        {
            Session.Worker = null;
            if (Session.Mode == Mode.Export) ShowExport(); else ShowImport();
            Window.SetFooter("Finish", true, false, "", () => Window.Close(), null);
        }
        private void ShowExport()
        {
            var dest = Session.Destination; _folder = dest;
            Window.SetHeader("All packed", "Your settings are in the backup location. Let OneDrive finish uploading before you use the new computer.");
            var mf = Path.Combine(dest, "manifest.json");
            NextTitle.Text = "Do this next";
            NextSteps.ItemsSource = new[] { new { N = 1, Text = "Wait for OneDrive to show the green tick on the PCMigration folder (the OneDrive icon bottom-right shows progress)." }, new { N = 2, Text = "On the new computer, sign in to OneDrive and start PC Migration from the same place." }, new { N = 3, Text = "Choose \"This is my new computer\" and follow the steps: install from the checklist, then restore." } };
            if (!File.Exists(mf)) { ErrBar.Visibility = Visibility.Visible; ErrBar.Title = "No backup was written"; ErrBar.Message = "manifest.json is missing from " + dest + ". Open the log (Logs, bottom left) to see why."; T1.Text = "0"; T1l.Text = "items packed"; T2.Text = "–"; T3.Text = "–"; return; }
            var m = Json.ParseObject(File.ReadAllText(mf));
            var entries = Json.Arr(m, "entries"); var secrets = Json.Arr(m, "secrets");
            double bytes = entries.Concat(secrets).Sum(e => Json.Num(e, "bytes"));
            T1.Text = (entries.Count + secrets.Count).ToString(); T1l.Text = "items packed";
            T2.Text = Fmt.Mb(bytes / 1048576.0); T2l.Text = "in the backup";
            var fails = entries.Where(e => Json.Arr(e, "failures").Count > 0).Select(e => Json.Str(e, "app")).ToList();
            var large = entries.SelectMany(e => Json.Arr(e, "largeFilesSkipped")).Select(x => Convert.ToString(x)).ToList();
            T3.Text = (fails.Count + large.Count).ToString(); T3l.Text = "need a look";
            if (fails.Count > 0) { FailBar.Visibility = Visibility.Visible; FailBar.Title = "Some files were in use"; FailBar.Message = "Packed only partly because a program had them open: " + string.Join(", ", fails) + ". Close that program and pack again, ticking just those items - the new run is merged into this folder."; }
            if (large.Count > 0) { LargeBar.Visibility = Visibility.Visible; LargeBar.Title = Fmt.Plural(large.Count, "very large file") + " left out"; LargeBar.Message = string.Join("\n", large.Take(8)) + (large.Count > 8 ? "\n…" : "") + "\nCopy them into OneDrive by hand if you need them (PST archives, for example)."; }
            _report = Path.Combine(dest, "report.md"); ReportBtn.Visibility = File.Exists(_report) ? Visibility.Visible : Visibility.Collapsed;
            _ext = Path.Combine(dest, "inventory", "browser-extensions.md"); ExtBtn.Visibility = File.Exists(_ext) ? Visibility.Visible : Visibility.Collapsed;
            var steps = Reports.ManualSteps(_report);
            if (steps.Count > 0) { ManualCard.Visibility = Visibility.Visible; ManualSub.Text = "Windows keeps these encrypted to this computer, so no tool can carry them. The same list is shown again at the end of the restore."; ManualSteps.ItemsSource = steps.Take(12).ToList(); }
        }
        private void ShowImport()
        {
            var src = Session.Backup.Path; _folder = src;
            Window.SetHeader("Restore finished", "Sign out and back in so Windows picks up the desktop, taskbar and Explorer settings.");
            _report = Reports.LatestImportReport(src);
            int ok, bad; List<string> waiting; Reports.ImportResults(_report, out ok, out bad, out waiting);
            T1.Text = ok.ToString(); T1l.Text = "items restored";
            T2.Text = bad.ToString(); T2l.Text = "with problems"; if (bad > 0) T2.Foreground = Theme.Brush("StatusCautionFg");
            T3.Text = waiting.Count.ToString(); T3l.Text = "waiting for a program";
            SignOutBtn.Visibility = Visibility.Visible; InstallBtn.Visibility = Visibility.Visible;
            ReportBtn.Visibility = _report != null ? Visibility.Visible : Visibility.Collapsed;
            _ext = Path.Combine(src, "inventory", "browser-extensions.md"); ExtBtn.Visibility = File.Exists(_ext) ? Visibility.Visible : Visibility.Collapsed;
            if (bad > 0) { FailBar.Visibility = Visibility.Visible; FailBar.Title = Fmt.Plural(bad, "item") + " could not be restored completely"; FailBar.Message = "Usually a file still open in a program. Close it and run the restore again for just that item - the report names each one."; }
            if (waiting.Count > 0) { WaitBar.Visibility = Visibility.Visible; WaitBar.Title = "Install these programs, then run PC Migration again"; WaitBar.Message = string.Join(", ", waiting) + ". Their settings are in the backup but the program is not on this computer yet; they are offered again once it is."; }
            NextTitle.Text = "Later";
            NextSteps.ItemsSource = new[] { new { N = 1, Text = "Sign out and back in: wallpaper, Explorer, taskbar and fonts only take effect then." }, new { N = 2, Text = "Installed more programs from the portal? Run PC Migration again and tick just their settings." }, new { N = 3, Text = "Everything replaced by the restore was backed up to AppData\\Local\\PCMigration-backup, in case you want something back." } };
            var steps = Reports.ManualSteps(Path.Combine(src, "report.md"));
            if (steps.Count > 0) { ManualCard.Visibility = Visibility.Visible; ManualSub.Text = "Windows keeps these encrypted to the old computer, so no tool can carry them."; ManualSteps.ItemsSource = steps; }
        }
        private async void SignOut_Click(object sender, RoutedEventArgs e) { if (await Window.Dialog("Sign out now?", "Save your work in other programs first. You will be signed out of Windows and can sign straight back in.", "Sign out", "Not yet")) Shell.SignOut(); }
        private void OpenFolder_Click(object sender, RoutedEventArgs e) { Shell.OpenFolder(_folder); }
        private void Report_Click(object sender, RoutedEventArgs e) { Shell.Open(_report); }
        private void Ext_Click(object sender, RoutedEventArgs e) { Shell.Open(_ext); }
        private void Install_Click(object sender, RoutedEventArgs e) { Session.InstallItems = null; Window.GoToStep("install"); }
    }
}
