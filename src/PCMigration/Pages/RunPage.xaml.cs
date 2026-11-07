using System;
using System.Linq;
using System.Windows;
using System.Windows.Threading;

namespace PCMigration.Pages
{
    /// <summary>The engine is running: live progress from its log.</summary>
    public partial class RunPage : AppPage
    {
        public override string StepKey { get { return "run"; } }
        private DispatcherTimer _clock;
        private Worker _w;
        public RunPage() { InitializeComponent(); }

        public override void OnShown()
        {
            bool export = Session.Mode == Mode.Export;
            _w = Session.Worker;
            Window.SetHeader(export ? "Packing your settings" : "Restoring your settings", "This takes a few minutes - browser profiles are the slow part. You can keep using the computer, but leave this window open.");
            Window.SetFooter("Continue", false, false, "", () => Window.GoToStep("done"), null);
            Session.LockPast();
            if (_w == null) { Status.Text = "Nothing is running."; Window.SetNextEnabled(true); return; }
            _w.Updated += Refresh; _w.Exited += Finished;
            _clock = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) }; _clock.Tick += (s, e) => Tick(); _clock.Start();
            Status.Text = "Starting…"; Refresh(); if (_w.HasExited) Finished();
        }
        public override void OnLeave() { if (_clock != null) _clock.Stop(); if (_w != null) { _w.Updated -= Refresh; _w.Exited -= Finished; } }

        private void Tick()
        {
            var t = DateTime.Now - Session.RunStarted; Elapsed.Text = t.ToString(t.TotalHours >= 1 ? @"h\:mm\:ss" : @"m\:ss") + " elapsed";
            bool net = System.Net.NetworkInformation.NetworkInterface.GetIsNetworkAvailable();
            if (_w != null && _w.Paused) { NetBar.Visibility = Visibility.Visible; NetBar.Severity = Controls.Severity.Warning; NetBar.Title = "Paused - waiting for the backup location"; NetBar.Message = "It resumes by itself when the location is reachable again; nothing is lost. After 60 minutes it stops cleanly and a later run continues where it left off."; }
            else if (!net) { NetBar.Visibility = Visibility.Visible; NetBar.Severity = Controls.Severity.Warning; NetBar.Title = "Network is down"; NetBar.Message = Session.Mode == Mode.Export ? "Packing continues into the local OneDrive folder; the upload happens when the network is back." : "The restore pauses when it needs a file that is still in the cloud, and resumes by itself."; }
            else NetBar.Visibility = Visibility.Collapsed;
        }
        private void Refresh()
        {
            if (_w == null) return;
            bool export = Session.Mode == Mode.Export;
            var phase = _w.Phase ?? "";
            if (phase.StartsWith("Phase 1")) Status.Text = export ? "Taking inventory of programs and settings…" : "Checking the backup…";
            else if (phase.StartsWith("Phase 2")) Status.Text = export ? "Looking through your profile folders…" : "Restoring settings…";
            else if (phase.StartsWith("Phase 3")) Status.Text = export ? "Packing settings…" : "Restoring environment, drives, printers and extensions…";
            int total = Math.Max(1, Session.SelectedIds.Count); int done = _w.DoneIds.Count(id => Session.SelectedIds.Contains(id));
            int pct = Math.Min(95, (int)(100.0 * done / total));
            if (phase.StartsWith("Phase 3") || (phase.StartsWith("Phase 2") && !export)) pct = Math.Max(pct, 10); else if (phase.Length > 0) pct = Math.Max(pct, 4);
            if (_w.HasExited) pct = 100;
            Bar.Value = pct; Percent.Text = pct + "%";
            Detail.Text = done + " of " + total + " items" + (_w.Warnings > 0 ? "  ·  " + Fmt.Plural(_w.Warnings, "warning") : "");
            Current.Text = _w.LastItem != null ? "Last: " + _w.LastItem : "";
            var text = _w.Text.ToString();
            if (Log.Text.Length != text.Length) { Log.Text = text; Log.ScrollToEnd(); }
        }
        private void Finished()
        {
            if (_clock != null) _clock.Stop(); Tick(); Refresh();
            ResultBar.Visibility = Visibility.Visible;
            if (_w.Failed)
            {
                Status.Text = "Stopped with an error"; Glyph.Text = "";
                ResultBar.Severity = Controls.Severity.Error; ResultBar.Title = "Something went wrong"; ResultBar.Message = (_w.StdErr ? FirstLines(_w.StdErrText, 3) : "The engine exited with code " + _w.ExitCode + ".") + " The full log is under Details.";
                LogExp.IsExpanded = true;
            }
            else if (_w.Warnings > 0 || _w.Errors > 0)
            {
                Status.Text = "Finished with remarks"; Glyph.Text = "";
                ResultBar.Severity = Controls.Severity.Warning; ResultBar.Title = Fmt.Plural(_w.Warnings + _w.Errors, "item") + " had a problem"; ResultBar.Message = "Usually a file that was open in a program. The next page explains what to do.";
            }
            else { Status.Text = "Finished"; Glyph.Text = ""; ResultBar.Severity = Controls.Severity.Success; ResultBar.Title = Session.Mode == Mode.Export ? "Everything is packed" : "Everything is restored"; ResultBar.Message = "Press Continue for the summary and what to do next."; }
            Window.SetNextEnabled(true);
        }
        private static string FirstLines(string s, int n) { return string.Join(" ", (s ?? "").Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).Take(n)); }
        private void Copy_Click(object sender, RoutedEventArgs e) { try { Clipboard.SetText(Log.Text); } catch { } }
        private void OpenLog_Click(object sender, RoutedEventArgs e) { if (_w != null && _w.LogPath != null) Shell.Open(_w.LogPath); }
    }
}
