using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace PCMigration.Pages
{
    /// <summary>The engine is running: live progress from its log, with Pause (finish the item in hand, continue later) and Cancel.</summary>
    public partial class RunPage : AppPage
    {
        public override string StepKey { get { return "run"; } }
        private DispatcherTimer _clock;
        private Worker _w;
        private bool _pauseRequested, _cancelled;
        public RunPage() { InitializeComponent(); }

        public override void OnShown()
        {
            bool export = Session.Mode == Mode.Export;
            _w = Session.Worker;
            Window.SetHeader(export ? "Packing your settings" : "Restoring your settings", "This takes a few minutes - browser profiles are the slow part. You can keep using the computer. Need to switch it off? Press Pause: the rest continues when you come back.");
            Window.SetFooter("Continue", false, false, "", () => Window.GoToStep("done"), null);
            Session.LockPast();
            if (_w == null) { Status.Text = "Nothing is running."; PauseBtn.IsEnabled = false; CancelBtn.IsEnabled = false; Window.SetNextEnabled(true); return; }
            _w.Updated += Refresh; _w.Exited += Finished;
            _clock = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) }; _clock.Tick += (s, e) => Tick(); _clock.Start();
            Status.Text = "Starting…"; Refresh(); if (_w.HasExited) Finished();
        }
        public override void OnLeave() { if (_clock != null) _clock.Stop(); if (_w != null) { _w.Updated -= Refresh; _w.Exited -= Finished; } }

        private void Tick()
        {
            var t = DateTime.Now - Session.RunStarted; Elapsed.Text = t.ToString(t.TotalHours >= 1 ? @"h\:mm\:ss" : @"m\:ss") + " elapsed";
            bool net = System.Net.NetworkInformation.NetworkInterface.GetIsNetworkAvailable();
            if (_w != null && _w.Paused) { NetBar.Visibility = Visibility.Visible; NetBar.Severity = Controls.Severity.Warning; NetBar.Title = "Waiting for the backup location"; NetBar.Message = "It resumes by itself when the location is reachable again; nothing is lost. After 60 minutes it stops cleanly and a later run continues where it left off."; }
            else if (!net) { NetBar.Visibility = Visibility.Visible; NetBar.Severity = Controls.Severity.Warning; NetBar.Title = "Network is down"; NetBar.Message = Session.Mode == Mode.Export ? "Packing continues into the local OneDrive folder; the upload happens when the network is back." : "The restore pauses when it needs a file that is still in the cloud, and resumes by itself."; }
            else NetBar.Visibility = Visibility.Collapsed;
        }
        private void Refresh()
        {
            if (_w == null) return;
            bool export = Session.Mode == Mode.Export;
            var phase = _w.Phase ?? "";
            if (_pauseRequested && !_w.HasExited) Status.Text = "Finishing the item in hand, then pausing…";
            else if (phase.StartsWith("Phase 1")) Status.Text = export ? "Taking inventory of programs and settings…" : "Checking the backup…";
            else if (phase.StartsWith("Phase 2")) Status.Text = export ? "Looking through your profile folders…" : "Restoring settings…";
            else if (phase.StartsWith("Phase 3")) Status.Text = export ? "Packing settings…" : "Restoring environment, drives, printers and extensions…";
            int total = Math.Max(1, Session.SelectedIds.Count); int done = _w.DoneIds.Count(id => Session.SelectedIds.Contains(id));
            int pct = Math.Min(95, (int)(100.0 * done / total));
            if (phase.StartsWith("Phase 3") || (phase.StartsWith("Phase 2") && !export)) pct = Math.Max(pct, 10); else if (phase.Length > 0) pct = Math.Max(pct, 4);
            if (_w.HasExited && !_w.PausedStop && !_cancelled) pct = 100;
            Bar.Value = pct; Percent.Text = pct + "%";
            Detail.Text = done + " of " + total + " items" + (_w.Warnings > 0 ? "  ·  " + Fmt.Plural(_w.Warnings, "warning") : "");
            Current.Text = _w.LastItem != null ? "Last: " + _w.LastItem : "";
            var text = _w.Text.ToString();
            if (Log.Text.Length != text.Length) { Log.Text = text; Log.ScrollToEnd(); }
        }
        private void Finished()
        {
            if (_clock != null) _clock.Stop(); Tick(); Refresh();
            PauseBtn.Visibility = Visibility.Collapsed; CancelBtn.Visibility = Visibility.Collapsed;
            if (_cancelled) return;
            ResultBar.Visibility = Visibility.Visible;
            if (_w.PausedStop)
            {
                int total = Session.SelectedIds.Count, left = _w.Remaining.Count;
                Runs.WriteResume(Session, _w.Remaining, total, total - left);
                Status.Text = "Paused"; Glyph.Text = "";
                ResultBar.Severity = Controls.Severity.Success; ResultBar.Title = "Paused - " + Fmt.Plural(left, "item") + " still to " + (Session.Mode == Mode.Export ? "pack" : "restore");
                ResultBar.Message = "What is done so far is safe in " + Session.RunFolder + ". Press Resume now to carry on, or Finish later: the first page of PC Migration offers to continue, also after switching the computer off.";
                ResumeBtn.Visibility = Visibility.Visible;
                Window.SetFooter("Finish later", true, false, "", () => { Session.Worker = null; Session.DefineSteps(Session.Mode); Window.GoToStep("start"); }, null);
                return;
            }
            Runs.ClearResume(Session.RunFolder);
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

        private void Pause_Click(object sender, RoutedEventArgs e)
        {
            if (_w == null || _w.HasExited) return;
            _pauseRequested = true; Runs.RequestPause(Session);
            PauseBtn.IsEnabled = false; PauseText.Text = "Pausing…"; Refresh();
        }
        private async void Resume_Click(object sender, RoutedEventArgs e)
        {
            var remaining = _w.Remaining.ToList(); if (remaining.Count == 0) return;
            string password = Session.SecretPassword;
            var secrets = Session.SecretIdsAll.Where(remaining.Contains).ToList();
            if (secrets.Count > 0 && password == null) { password = await Window.AskPassword("Keys and passwords", Fmt.Plural(secrets.Count, "encrypted item") + " still to go. Enter the bundle password, or leave it empty to skip them."); if (string.IsNullOrEmpty(password)) { remaining = remaining.Where(id => !secrets.Contains(id)).ToList(); password = null; } }
            if (remaining.Count == 0) return;
            if (Session.Mode == Mode.Export) Runs.StartExport(Session, Session.RunFolder, remaining, password, Dispatcher);
            else Runs.StartImport(Session, Session.RunFolder, remaining, password, Session.RestoreEvenIfMissing, Session.ForceIds, Dispatcher);
            Window.Navigate(new RunPage());
        }
        private async void Cancel_Click(object sender, RoutedEventArgs e)
        {
            if (_w == null || _w.HasExited) return;
            bool export = Session.Mode == Mode.Export;
            var msg = export
                ? "The packing stops at once and the backup folder made by this run is deleted:\n" + Session.RunFolder + "\n\nNothing on this computer has been changed."
                : "The restore stops at once. Settings already put back stay as they are (what they replaced was backed up first under AppData\\Local\\PCMigration-backup); temporary files are removed and the backup itself is kept.";
            if (!await Window.Dialog(export ? "Cancel and delete the backup?" : "Cancel the restore?", msg, export ? "Cancel and delete" : "Cancel the restore", "Keep going")) return;
            _cancelled = true; PauseBtn.IsEnabled = false; CancelBtn.IsEnabled = false; Status.Text = "Stopping…";
            _w.Kill();
            await Task.Run(() => { for (int i = 0; i < 100 && !_w.HasExited; i++) System.Threading.Thread.Sleep(100); });
            await Task.Run(() =>
            {
                Runs.DeleteTree(Runs.StageDir(Session.Mode));
                if (export) Runs.DeleteTree(Session.RunFolder);
                else { Runs.ClearResume(Session.RunFolder); try { System.IO.File.Delete(Runs.PausePath(Session.RunFolder)); } catch { } }
            });
            Session.Worker = null;
            Status.Text = "Cancelled"; Glyph.Text = ""; Bar.Value = 0; Percent.Text = "";
            ResultBar.Visibility = Visibility.Visible; ResultBar.Severity = Controls.Severity.Warning;
            ResultBar.Title = export ? "Cancelled - the backup folder was deleted" : "Cancelled";
            ResultBar.Message = export ? (System.IO.Directory.Exists(Session.RunFolder) ? "Some files in " + Session.RunFolder + " could not be removed (still in use); delete the folder by hand." : "Nothing of this run is left. Choose what to take again whenever you like.") : "Settings restored before the stop stay in place. Run the restore again any time; it only touches what you tick.";
            Window.SetFooter("Start over", true, false, "", () => { Session.DefineSteps(Session.Mode); Window.GoToStep("start"); }, null);
        }
        private static string FirstLines(string s, int n) { return string.Join(" ", (s ?? "").Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).Take(n)); }
        private void Copy_Click(object sender, RoutedEventArgs e) { try { Clipboard.SetText(Log.Text); } catch { } }
        private void OpenLog_Click(object sender, RoutedEventArgs e) { if (_w != null && _w.LogPath != null) Shell.Open(_w.LogPath); }
    }
}
