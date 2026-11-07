using System;
using System.Linq;
using System.Windows;

namespace PCMigration.Pages
{
    public partial class StartPage : AppPage
    {
        private BackupInfo _resume;
        private ResumeInfo _paused; private BackupInfo _pausedBackup;
        public override string StepKey { get { return "start"; } }
        public StartPage() { InitializeComponent(); RootBar.ActionClick += (s, e) => Window.ChangeRoot(); ResumeBar.ActionClick += (s, e) => Resume(); PausedBar.ActionClick += (s, e) => ResumePaused(); }

        public override void OnShown()
        {
            Window.SetHeader("Welcome", "Move your settings from your old computer to the new one. Nothing is installed, no administrator rights are needed, and nothing outside your own profile is touched.");
            if (Session.Mode == Mode.None) Session.DefineSteps(Mode.Export);
            Session.GoTo("start");
            OldCard.IsChecked = Session.Mode == Mode.Export; NewCard.IsChecked = Session.Mode == Mode.Import;
            Refresh();
        }
        public override void OnRootChanged() { Refresh(); }

        private async void Refresh()
        {
            var env = Session.Env;
            RootBar.Visibility = env == null || string.IsNullOrEmpty(env.BackupRoot) ? Visibility.Visible : Visibility.Collapsed;
            if (env != null && env.Admin) { AdminBar.Visibility = Visibility.Visible; AdminBar.Message = "Everything still works, but what gets packed or restored belongs to the account this window runs as: " + env.User + ". If that is not you, close this and start it normally."; }
            UpdateFooter();
            if (env == null || string.IsNullOrEmpty(env.BackupRoot)) { Guess.Text = ""; return; }
            try
            {
                var r = await Engine.Probe("backups");
                var backups = Json.Arr(r, "backups").Select(BackupInfo.From).ToList();
                // a pack or restore that was paused on this computer
                _paused = null; _pausedBackup = null;
                foreach (var b in backups) { var rs = Runs.ReadResume(b.Path); if (rs != null) { _paused = rs; _pausedBackup = b; break; } }
                if (_paused != null)
                {
                    PausedBar.Visibility = Visibility.Visible;
                    PausedBar.Title = (_paused.Mode == Mode.Export ? "Packing" : "Restoring") + " was paused on " + Fmt.When(_paused.At);
                    PausedBar.Message = Fmt.Plural(_paused.Remaining.Count, "item") + " of " + _paused.Total + " still to " + (_paused.Mode == Mode.Export ? "pack into " : "restore from ") + _pausedBackup.Name + ". Press Resume to carry on exactly where it stopped" + (_paused.KitVersion != Kit.Version ? " (paused with version " + _paused.KitVersion + ", this is " + Kit.Version + ")" : "") + ".";
                }
                else PausedBar.Visibility = Visibility.Collapsed;
                _resume = backups.FirstOrDefault(b => b.InProgress && !b.MadeHere) ?? backups.FirstOrDefault(b => b.InProgress);
                if (_resume != null)
                {
                    ResumeBar.Visibility = Visibility.Visible;
                    ResumeBar.Message = "A restore onto this computer from the backup of " + _resume.Computer + " is in progress: " + _resume.ChecklistInstalled + " installed and " + _resume.ChecklistSkipped + " skipped on the install list, " + _resume.Restored + " settings restored so far.";
                }
                else ResumeBar.Visibility = Visibility.Collapsed;
                var other = backups.FirstOrDefault(b => !b.MadeHere);
                if (other != null) Guess.Text = "Found a backup from " + other.Computer + " made " + Fmt.When(other.Created) + " in the backup location - this looks like your new computer.";
                else if (backups.Count > 0) Guess.Text = "The only backup in the backup location was made on this computer (" + Fmt.When(backups[0].Created) + ").";
                else Guess.Text = "No backup in the backup location yet, so this is probably your old computer.";
                if (!_userChose && Session.Mode == Mode.Export && other != null && !backups.Any(b => b.MadeHere)) { NewCard.IsChecked = true; }
            }
            catch (EngineException ex) { Guess.Text = ex.Message; }
        }
        private bool _userChose;
        private void Role_Checked(object sender, RoutedEventArgs e)
        {
            if (Window == null) return;
            var mode = OldCard.IsChecked == true ? Mode.Export : Mode.Import;
            if (sender != null && IsLoaded) _userChose = true;
            if (Session.Mode != mode) { Session.DefineSteps(mode); Session.GoTo("start"); Window.Navigate(this); return; }
            UpdateFooter();
        }
        private void UpdateFooter()
        {
            bool ok = Session.Env != null && !string.IsNullOrEmpty(Session.Env.BackupRoot) && (OldCard.IsChecked == true || NewCard.IsChecked == true);
            Window.SetFooter("Next", ok, false, "", () => Window.GoToStep(Session.Mode == Mode.Export ? "scan" : "backup"), null);
        }
        private async void ResumePaused()
        {
            var r = _paused; if (r == null) return;
            Session.DefineSteps(r.Mode); Session.ResumeSecretIds = r.SecretIds; Session.SecretPassword = null;
            var remaining = r.Remaining.ToList();
            if (r.SecretIds.Count > 0)
            {
                var pw = await Window.AskPassword("Keys and passwords", Fmt.Plural(r.SecretIds.Count, "encrypted item") + " among the rest. Enter the bundle password, or leave it empty to skip them this time.");
                if (string.IsNullOrEmpty(pw)) remaining = remaining.Where(id => !r.SecretIds.Contains(id)).ToList(); else Session.SecretPassword = pw;
            }
            if (remaining.Count == 0) { Runs.ClearResume(r.Folder); Refresh(); return; }
            if (r.Mode == Mode.Export) Runs.StartExport(Session, r.Folder, remaining, Session.SecretPassword, Dispatcher);
            else { Session.Backup = _pausedBackup; Runs.StartImport(Session, r.Folder, remaining, Session.SecretPassword, r.RestoreEvenIfMissing, r.ForceIds, Dispatcher); }
            Session.SelectedIds = remaining;
            Window.GoToStep("run");
        }
        private async void Discard_Click(object sender, RoutedEventArgs e)
        {
            var r = _paused; if (r == null) return;
            if (r.Mode == Mode.Export)
            {
                if (!await Window.Dialog("Discard the paused packing?", "The backup folder made by that run is deleted:\n" + r.Folder, "Delete it", "Keep it")) return;
                await System.Threading.Tasks.Task.Run(() => Runs.DeleteTree(r.Folder));
            }
            else { if (!await Window.Dialog("Discard the paused restore?", "The restore is not continued; what was restored so far stays. The backup itself is kept.", "Discard", "Keep it")) return; Runs.ClearResume(r.Folder); }
            Refresh();
        }
        private void Resume()
        {
            if (_resume == null) return;
            if (Session.Mode != Mode.Import) { Session.DefineSteps(Mode.Import); }
            Session.Backup = _resume; Session.InstallItems = null; Session.ImportGroups = null;
            Window.GoToStep("install");
        }
    }
}
