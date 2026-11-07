using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;

namespace PCMigration
{
    public enum Mode { None, Export, Import }

    public class Step : Observable
    {
        public string Key { get; set; }
        public string Title { get; set; }
        public string Hint { get; set; }
        public int Number { get; set; }
        public string AutomationName { get { return "Step " + Number + ": " + Title; } }
        private string _state = "upcoming"; public string State { get { return _state; } set { if (Set(ref _state, value)) { Raise("IsCurrent"); Raise("IsDone"); Raise("IsUpcoming"); Raise("Glyph"); Raise("CanNavigate"); } } }
        public bool IsCurrent { get { return _state == "current"; } }
        public bool IsDone { get { return _state == "done"; } }
        public bool IsUpcoming { get { return _state == "upcoming"; } }
        public bool Locked { get; set; }
        public bool CanNavigate { get { return _state == "done" && !Locked; } }
        public string Glyph { get { return _state == "done" ? "" : Number.ToString(); } }
        public void RaiseAll() { Raise("CanNavigate"); Raise("IsDone"); Raise("IsCurrent"); }
    }

    /// <summary>Everything the pages share: what the user chose, where things are, what is running.</summary>
    public class Session
    {
        public static Session Current { get; private set; }
        public Session() { Current = this; }

        public Mode Mode { get; set; }
        public Environment2 Env { get; set; }
        public string BackupRoot { get { return Env != null ? Env.BackupRoot : null; } }
        public ObservableCollection<Step> Steps { get; private set; } = new ObservableCollection<Step>();
        public Step CurrentStep { get; private set; }

        // export
        public List<SelectionGroup> ExportGroups { get; set; }
        public List<object> ExtraEntries { get; set; } = new List<object>();      // discovered + custom definitions that travel in extra-entries.json
        public List<SelectionItem> CustomItems { get; set; } = new List<SelectionItem>();
        public bool DiscoveryDone { get; set; }
        public List<SelectionItem> DiscoveredItems { get; set; }
        public string Destination { get; set; }
        public string SecretPassword { get; set; }

        // import
        public BackupInfo Backup { get; set; }
        public List<SelectionGroup> ImportGroups { get; set; }
        public bool ImportSecretsEncrypted { get; set; }
        public bool RestoreEvenIfMissing { get; set; }
        public List<InstallItem> InstallItems { get; set; }

        // run
        public List<string> SelectedIds { get; set; } = new List<string>();
        public Worker Worker { get; set; }
        public DateTime RunStarted { get; set; }

        public void DefineSteps(Mode mode)
        {
            Mode = mode; Steps.Clear();
            string[][] def = mode == Mode.Export
                ? new[] { new[] { "start", "Start", "Which computer is this" }, new[] { "scan", "Scan", "What this PC holds" }, new[] { "select", "Choose", "What to take" }, new[] { "review", "Review", "Check before packing" }, new[] { "run", "Pack", "Copying into the backup" }, new[] { "done", "Done", "Next steps" } }
                : new[] { new[] { "start", "Start", "Which computer is this" }, new[] { "backup", "Backup", "Which backup to use" }, new[] { "install", "Install", "Programs to put back" }, new[] { "select", "Choose", "What to restore" }, new[] { "review", "Review", "Check before restoring" }, new[] { "run", "Restore", "Putting settings back" }, new[] { "done", "Done", "What is left to do" } };
            int n = 1; foreach (var d in def) Steps.Add(new Step { Key = d[0], Title = d[1], Hint = d[2], Number = n++ });
        }
        public void GoTo(string key)
        {
            var target = Steps.FirstOrDefault(s => s.Key == key); if (target == null) return;
            foreach (var s in Steps) s.State = s.Number < target.Number ? "done" : s.Number == target.Number ? "current" : "upcoming";
            CurrentStep = target;
        }
        public void LockPast() { foreach (var s in Steps) { s.Locked = true; s.RaiseAll(); } }
    }

    public static class Shell
    {
        public static void Open(string target) { try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch (Exception ex) { Engine.Log("open " + target + ": " + ex.Message); } }
        public static void OpenFolder(string path) { try { Process.Start("explorer.exe", "\"" + path + "\""); } catch { } }
        public static void RunInPowerShell(string command) { try { Process.Start(new ProcessStartInfo("powershell.exe", "-NoExit -NoProfile -ExecutionPolicy Bypass -Command \"" + command.Replace("\"", "\\\"") + "\"") { UseShellExecute = true }); } catch { } }
        public static void SignOut() { try { Process.Start("shutdown.exe", "/l"); } catch { } }
        public static List<string> Running(IEnumerable<string> processNames) { var o = new List<string>(); foreach (var n in processNames) { try { if (Process.GetProcessesByName(n).Length > 0) o.Add(n); } catch { } } return o; }
        public static void CloseGracefully(IEnumerable<string> processNames) { foreach (var n in processNames) { try { foreach (var p in Process.GetProcessesByName(n)) { try { p.CloseMainWindow(); } catch { } } } catch { } } }
    }
}
