using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Threading;

namespace PCMigration.Pages
{
    /// <summary>The last look before anything is written: what, where, how much, and what is still in the way.</summary>
    public partial class ReviewPage : AppPage
    {
        public override string StepKey { get { return "review"; } }
        private DispatcherTimer _timer;
        private List<string> _running = new List<string>();
        public ReviewPage() { InitializeComponent(); OpenBar.ActionClick += (s, e) => Shell.CloseGracefully(_running); }

        public override void OnShown()
        {
            bool export = Session.Mode == Mode.Export;
            var groups = export ? Session.ExportGroups : Session.ImportGroups;
            if (groups == null) { Window.GoToStep(export ? "scan" : "backup"); return; }
            var selected = groups.SelectMany(g => g.Items).Where(i => Session.SelectedIds.Contains(i.Id)).ToList();
            var env = Session.Env;
            if (export)
            {
                Window.SetHeader("Ready to pack", "Check the summary, then press Pack. Everything goes into one new folder in the backup location; nothing on this computer is changed.");
                Session.Destination = Path.Combine(env.BackupRoot, env.Computer + "-" + env.User.Substring(env.User.IndexOf('\\') + 1) + "-" + DateTime.Now.ToString("yyyyMMdd-HHmm"));
                WhereTitle.Text = "Packed into"; WherePath.Text = Session.Destination;
                T1.Text = selected.Count.ToString(); T1l.Text = "items to pack";
                T2.Text = Fmt.Mb(selected.Sum(i => i.SizeMb ?? 0)) + (selected.Any(i => i.SizeMb == null) ? "+" : ""); T2l.Text = "estimated size before compression";
                var sec = selected.Count(i => i.IsSecret); T3.Text = sec.ToString(); T3l.Text = sec > 0 ? "keys and passwords, encrypted" : "keys and passwords (none)";
                NetBar.Visibility = Visibility.Visible;
                NetBar.Message = env.NetworkAvailable ? "Packing into a local OneDrive folder needs no network; the upload happens afterwards. Wait for the green tick on the folder before using the new computer." : "No network right now. Packing still works (the folder is local); OneDrive uploads it when the network is back.";
                NetBar.Title = env.OneDriveRunning ? "OneDrive is running" : "OneDrive is not running"; NetBar.Severity = env.OneDriveRunning ? Controls.Severity.Informational : Controls.Severity.Warning;
                CheckSpace(selected.Sum(i => i.SizeMb ?? 0), env.BackupRoot);
                Note.Text = "Open programs lock their files: whatever is still open is packed only partly and listed on the result page. A second pack into the same folder merges and fills the gaps.";
                Window.SetFooter("Pack my settings", true, true, "", StartExport, () => Window.GoToStep("select"));
            }
            else
            {
                Window.SetHeader("Ready to restore", "Check the summary, then press Restore. Anything replaced on this computer is backed up first under AppData\\Local\\PCMigration-backup.");
                WhereTitle.Text = "Restored from the backup of " + Session.Backup.Computer; WherePath.Text = Session.Backup.Path;
                T1.Text = selected.Count.ToString(); T1l.Text = "items to restore";
                T2.Text = Fmt.Mb(selected.Sum(i => i.SizeMb ?? 0)); T2l.Text = "packed size";
                var sec = selected.Count(i => i.IsSecret); T3.Text = sec.ToString(); T3l.Text = sec > 0 ? "keys and passwords to decrypt" : "keys and passwords (none)";
                if (Session.Backup.Placeholders > 0) { NetBar.Visibility = Visibility.Visible; NetBar.Severity = Controls.Severity.Warning; NetBar.Title = Session.Backup.Placeholders + " files are still only in the cloud"; NetBar.Message = "The restore pauses whenever it needs a file that is not downloaded yet and resumes by itself when OneDrive delivers it. Faster: go back to the Backup step and press Download everything now."; }
                else if (!env.NetworkAvailable) { NetBar.Visibility = Visibility.Visible; NetBar.Severity = Controls.Severity.Warning; NetBar.Title = "No network"; NetBar.Message = "Every file of this backup is already on this computer, so the restore can run without the network."; }
                OptionsCard.Visibility = Visibility.Visible; ForceCb.IsChecked = Session.RestoreEvenIfMissing;
                Note.Text = "Settings of a program that is still open are skipped this time and offered again on the next run.";
                Window.SetFooter("Restore my settings", true, true, "", StartImport, () => Window.GoToStep("select"));
            }
            GroupRows.ItemsSource = groups.Where(g => g.Items.Any(i => Session.SelectedIds.Contains(i.Id))).Select(g => new { g.Glyph, g.Title, Count = g.Items.Count(i => Session.SelectedIds.Contains(i.Id)) + " of " + g.Items.Count + "  ·  " + Fmt.Mb(g.Items.Where(i => Session.SelectedIds.Contains(i.Id)).Sum(i => i.SizeMb ?? 0)), Names = string.Join(", ", g.Items.Where(i => Session.SelectedIds.Contains(i.Id)).Select(i => i.Name)) }).ToList();
            RefreshOpen();
            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) }; _timer.Tick += (s, e) => RefreshOpen(); _timer.Start();
        }
        public override void OnLeave() { if (_timer != null) _timer.Stop(); }
        private double _needMb, _freeMb = -1;
        /// <summary>Is there room for the backup? Uncompressed size is the conservative bound (zips come out smaller).</summary>
        private void CheckSpace(double needMb, string root)
        {
            _needMb = needMb; var free = Native.FreeMb(root); _freeMb = free ?? -1;
            SpaceBar.Visibility = Visibility.Visible;
            if (free == null) { SpaceBar.Severity = Controls.Severity.Warning; SpaceBar.Title = "Free space at the backup location could not be read"; SpaceBar.Message = "Make sure " + root + " has room for about " + Fmt.Mb(needMb) + "."; return; }
            if (free.Value < needMb) { SpaceBar.Severity = Controls.Severity.Error; SpaceBar.Title = "Not enough space at the backup location"; SpaceBar.Message = Fmt.Mb(free.Value) + " free, about " + Fmt.Mb(needMb) + " needed before compression. Untick large items, free up space, or change the backup location (bottom left)."; }
            else if (free.Value < needMb * 1.5) { SpaceBar.Severity = Controls.Severity.Warning; SpaceBar.Title = "Space is tight at the backup location"; SpaceBar.Message = Fmt.Mb(free.Value) + " free for about " + Fmt.Mb(needMb) + ". Zips come out smaller, so it will probably fit - but a OneDrive folder also needs the same room in the cloud."; }
            else { SpaceBar.Severity = Controls.Severity.Success; SpaceBar.Title = "Enough space at the backup location"; SpaceBar.Message = Fmt.Mb(free.Value) + " free for about " + Fmt.Mb(needMb) + "."; }
        }
        private void ForceCb_Changed(object sender, RoutedEventArgs e) { Session.RestoreEvenIfMissing = ForceCb.IsChecked == true; }

        private void RefreshOpen()
        {
            if (Session.Mode == Mode.Export)
            {
                _running = Apps.RunningEditors();
                OpenBar.Title = "Programs still open: " + string.Join(", ", _running.Select(Apps.Friendly).Distinct());
                OpenBar.Message = "Anything these have not written to disk yet (unsaved tabs, documents) will be missing from the backup, and files they hold open cannot be copied.";
            }
            else
            {
                _running = Apps.RunningOwners(Session.SelectedIds);
                var blocked = Apps.IdsBlockedBy(_running, Session.SelectedIds);
                OpenBar.Title = "Programs still open: " + string.Join(", ", _running);
                OpenBar.Message = Fmt.Plural(blocked.Count, "setting") + " belong to them and would be skipped this time: " + string.Join(", ", blocked.Take(6)) + (blocked.Count > 6 ? ", …" : "") + ". Save your work and close them first.";
            }
            OpenBar.Visibility = _running.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        private async void StartExport()
        {
            if (_freeMb >= 0 && _freeMb < _needMb && !await Window.Dialog("Not enough space", "The backup location has " + Fmt.Mb(_freeMb) + " free and about " + Fmt.Mb(_needMb) + " is needed. Packing would stop half way. Change the backup location or untick large items first.", "Pack anyway", "Go back")) return;
            if (_running.Count > 0 && !await Window.Dialog("Programs are still open", string.Join(", ", _running.Select(Apps.Friendly).Distinct()) + ". Anything not yet written to disk by these programs will be missing from the backup. Pack anyway?", "Pack anyway", "Go back")) return;
            var ids = Session.SelectedIds;
            var extras = Session.ExportGroups.SelectMany(g => g.Items).Where(i => i.Extra != null && (ids.Contains(i.Id) || i.Category == "custom")).Select(i => i.Extra).ToList();
            Directory.CreateDirectory(Session.Destination);
            if (extras.Count > 0) File.WriteAllText(Path.Combine(Session.Destination, "extra-entries.json"), Json.Serialize(new Dictionary<string, object> { { "entries", extras } }), System.Text.Encoding.UTF8);
            Runs.StartExport(Session, Session.Destination, ids, Session.SecretPassword, Dispatcher);
            Window.GoToStep("run");
        }
        private async void StartImport()
        {
            var ids = Session.SelectedIds.ToList();
            if (_running.Count > 0)
            {
                var blocked = Apps.IdsBlockedBy(_running, ids);
                if (blocked.Count > 0)
                {
                    if (!await Window.Dialog("Programs are still open", string.Join(", ", _running) + ". Continue and skip their " + Fmt.Plural(blocked.Count, "setting") + " for now? They are offered again on the next run.", "Skip them and restore the rest", "Go back")) return;
                    ids = ids.Where(i => !blocked.Contains(i)).ToList();
                    if (ids.Count == 0) { await Window.Dialog("Nothing left to restore", "Every selected item belongs to a program that is still open.", "OK", null); return; }
                }
            }
            Session.SelectedIds = ids;
            var secrets = Session.ImportGroups.SelectMany(g => g.Items).Where(i => i.IsSecret && ids.Contains(i.Id)).ToList();
            var force = Session.ImportGroups.SelectMany(g => g.Items).Where(i => i.Force && ids.Contains(i.Id)).Select(i => i.Id).ToList();
            Runs.StartImport(Session, Session.Backup.Path, ids, secrets.Count > 0 ? Session.SecretPassword : null, Session.RestoreEvenIfMissing, force, Dispatcher);
            Window.GoToStep("run");
        }
    }
}
