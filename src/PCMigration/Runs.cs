using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows.Threading;

namespace PCMigration
{
    /// <summary>A run that was paused (by the Pause button, or by closing the window) and can be continued later.</summary>
    public class ResumeInfo
    {
        public Mode Mode;
        public string Folder;            // the backup folder (destination when packing, source when restoring)
        public DateTime At;
        public List<string> Remaining = new List<string>();
        public List<string> SecretIds = new List<string>();
        public List<string> ForceIds = new List<string>();
        public bool RestoreEvenIfMissing;
        public int Total, Done;
        public string KitVersion;
    }

    /// <summary>Starts the engine for a pack or a restore, and keeps the resume record that lets a paused run continue later.</summary>
    public static class Runs
    {
        public static string ResumePath(string folder) { return Path.Combine(folder, "resume-" + Environment.MachineName + ".json"); }
        public static string PausePath(string folder) { return Path.Combine(folder, ".pause-request-" + Environment.MachineName); }
        public static string StageDir(Mode mode) { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Temp", mode == Mode.Export ? "PCMigration-stage" : "PCMigration-restore"); }

        public static Worker StartExport(Session s, string dest, List<string> ids, string password, Dispatcher d)
        {
            Directory.CreateDirectory(dest);
            var args = "-Destination " + Engine.Quote(dest) + " -Include " + Engine.Quote(string.Join(",", ids)) + (password != null ? " -IncludeSecrets" : "");
            s.Mode = Mode.Export; s.RunFolder = dest; s.Destination = dest; s.SelectedIds = ids; s.SecretPassword = password; s.RunStarted = DateTime.Now;
            s.Worker = Engine.Start("Export-Profile.ps1", args, password, d);
            return s.Worker;
        }
        public static Worker StartImport(Session s, string source, List<string> ids, string password, bool evenIfMissing, List<string> forceIds, Dispatcher d)
        {
            var args = "-Source " + Engine.Quote(source) + " -Include " + Engine.Quote(string.Join(",", ids)) + " -Force" + (password != null ? " -IncludeSecrets" : "") + (evenIfMissing ? " -RestoreEvenIfMissing" : "") + (forceIds != null && forceIds.Count > 0 ? " -ForceIds " + Engine.Quote(string.Join(",", forceIds)) : "");
            s.Mode = Mode.Import; s.RunFolder = source; s.SelectedIds = ids; s.SecretPassword = password; s.RestoreEvenIfMissing = evenIfMissing; s.ForceIds = forceIds ?? new List<string>(); s.RunStarted = DateTime.Now;
            s.Worker = Engine.Start("Import-Profile.ps1", args, password, d);
            return s.Worker;
        }

        /// <summary>Asks the running engine to stop after the item in hand.</summary>
        public static void RequestPause(Session s) { try { File.WriteAllText(PausePath(s.RunFolder), DateTime.Now.ToString("o")); } catch (Exception ex) { Engine.Log("pause request: " + ex.Message); } }

        public static void WriteResume(Session s, List<string> remaining, int total, int done)
        {
            var secretIds = s.SecretIdsAll.Where(remaining.Contains).ToList();
            var o = new Dictionary<string, object>
            {
                { "mode", s.Mode == Mode.Export ? "export" : "import" }, { "computer", Environment.MachineName }, { "at", DateTime.Now.ToString("o") }, { "folder", s.RunFolder },
                { "remaining", remaining }, { "secretIds", secretIds }, { "forceIds", s.ForceIds ?? new List<string>() }, { "restoreEvenIfMissing", s.RestoreEvenIfMissing }, { "total", total }, { "done", done }, { "kitVersion", Kit.Version }
            };
            try { File.WriteAllText(ResumePath(s.RunFolder), Json.Serialize(o), System.Text.Encoding.UTF8); } catch (Exception ex) { Engine.Log("resume record: " + ex.Message); }
        }
        public static ResumeInfo ReadResume(string folder)
        {
            var p = ResumePath(folder);
            if (!File.Exists(p)) return null;
            try
            {
                var o = Json.ParseObject(File.ReadAllText(p));
                var r = new ResumeInfo { Mode = Json.Str(o, "mode") == "export" ? Mode.Export : Mode.Import, Folder = Json.Str(o, "folder", folder), At = Json.Date(o, "at") ?? File.GetLastWriteTime(p), RestoreEvenIfMissing = Json.Bool(o, "restoreEvenIfMissing"), Total = (int)Json.Num(o, "total"), Done = (int)Json.Num(o, "done"), KitVersion = Json.Str(o, "kitVersion") };
                r.Remaining = Json.Arr(o, "remaining").Select(x => Convert.ToString(x)).ToList();
                r.SecretIds = Json.Arr(o, "secretIds").Select(x => Convert.ToString(x)).ToList();
                r.ForceIds = Json.Arr(o, "forceIds").Select(x => Convert.ToString(x)).ToList();
                return r.Remaining.Count > 0 ? r : null;
            }
            catch { return null; }
        }
        public static void ClearResume(string folder) { try { File.Delete(ResumePath(folder)); } catch { } }

        /// <summary>Removes a folder of any depth (robocopy mirrors an empty folder over it when Directory.Delete gives up).</summary>
        public static bool DeleteTree(string path)
        {
            if (string.IsNullOrEmpty(path) || path.Length < 8 || !Directory.Exists(path)) return true;
            try { Directory.Delete(path, true); } catch { }
            if (!Directory.Exists(path)) return true;
            var empty = Path.Combine(Path.GetTempPath(), "migempty-" + Guid.NewGuid().ToString("N"));
            try
            {
                Directory.CreateDirectory(empty);
                var p = Process.Start(new ProcessStartInfo("robocopy.exe", "\"" + empty + "\" \"" + path + "\" /MIR /NJH /NJS /NFL /NDL /NP /R:0 /W:0") { CreateNoWindow = true, UseShellExecute = false }); p.WaitForExit();
                Directory.Delete(path, true); Directory.Delete(empty, true);
            }
            catch (Exception ex) { Engine.Log("delete " + path + ": " + ex.Message); }
            return !Directory.Exists(path);
        }
    }
}
