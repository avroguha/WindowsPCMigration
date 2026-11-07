using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace PCMigration
{
    /// <summary>Runs the PowerShell engine in hidden child processes: read-only probes that answer JSON, and the three workers
    /// (export, compare, import) whose log lines are streamed back as they appear.</summary>
    public static class Engine
    {
        private static ProcessStartInfo Psi(string script, string args)
        {
            var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + Kit.Script(script) + "\" " + args)
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Kit.Dir, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
            if (!string.IsNullOrEmpty(Kit.BackupRootOverride)) psi.EnvironmentVariables["PCMIG_ROOT"] = Kit.BackupRootOverride;
            return psi;
        }
        public static string Quote(string s) { return "\"" + s.Replace("\"", "\\\"") + "\""; }

        /// <summary>Runs UI-Probe.ps1 and returns its JSON (parsed) on a worker thread.</summary>
        public static Task<Dictionary<string, object>> Probe(string mode, string extraArgs = "")
        {
            return Task.Run(() =>
            {
                var psi = Psi("UI-Probe.ps1", "-Mode " + mode + " " + extraArgs);
                using (var p = Process.Start(psi))
                {
                    var outTask = p.StandardOutput.ReadToEndAsync(); var errTask = p.StandardError.ReadToEndAsync();
                    p.WaitForExit();
                    var text = outTask.Result; var err = errTask.Result;
                    Log("probe " + mode + " exit " + p.ExitCode + (err.Trim().Length > 0 ? "\n" + err : ""));
                    if (p.ExitCode != 0 || text.Trim().Length == 0) throw new EngineException("The migration engine could not answer (" + mode + ").", err);
                    try { return Json.ParseObject(text); } catch (Exception ex) { throw new EngineException("The migration engine returned something unexpected (" + mode + ").", ex.Message + "\n" + Head(text, 2000)); }
                }
            });
        }

        /// <summary>Streams `{"id":..,"mb":..}` lines from the size probe to the UI thread as they are produced.</summary>
        public static Process ProbeSizes(IEnumerable<string> ids, Dispatcher ui, Action<string, double> onSize, Action onDone)
        {
            var psi = Psi("UI-Probe.ps1", "-Mode sizes -Ids " + Quote(string.Join(",", ids)));
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            p.OutputDataReceived += (s, e) =>
            {
                if (string.IsNullOrWhiteSpace(e.Data)) return;
                try { var o = Json.ParseObject(e.Data); var id = Json.Str(o, "id"); var mb = Json.Num(o, "mb"); ui.BeginInvoke(new Action(() => onSize(id, mb))); } catch { }
            };
            p.Exited += (s, e) => ui.BeginInvoke(new Action(onDone));
            p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine();
            return p;
        }

        /// <summary>Starts one of the three worker scripts; log lines come back on the UI thread.</summary>
        public static Worker Start(string script, string args, string secretPassword, Dispatcher ui)
        {
            var psi = Psi(script, args);
            if (!string.IsNullOrEmpty(secretPassword)) psi.EnvironmentVariables["PCMIG_SECRET_PW"] = secretPassword;
            var w = new Worker(script);
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            var logPath = Path.Combine(Kit.LogDir, Path.GetFileNameWithoutExtension(script) + "-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log");
            w.LogPath = logPath;
            var sink = new StreamWriter(logPath, false, Encoding.UTF8) { AutoFlush = true };
            p.OutputDataReceived += (s, e) => { if (e.Data == null) return; lock (sink) sink.WriteLine(e.Data); ui.BeginInvoke(new Action(() => w.AddLine(e.Data, false))); };
            p.ErrorDataReceived += (s, e) => { if (e.Data == null) return; lock (sink) sink.WriteLine("STDERR " + e.Data); ui.BeginInvoke(new Action(() => w.AddLine(e.Data, true))); };
            p.Exited += (s, e) => { Thread.Sleep(200); ui.BeginInvoke(new Action(() => { w.Finish(p.ExitCode); lock (sink) sink.Dispose(); })); };
            w.Process = p;
            p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine();
            Log("start " + script + " " + args.Replace(secretPassword ?? "\u0001", "***"));
            return w;
        }

        public static void Log(string text) { try { File.AppendAllText(Path.Combine(Kit.LogDir, "app.log"), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss ") + text + Environment.NewLine); } catch { } }
        private static string Head(string s, int n) { return s.Length <= n ? s : s.Substring(0, n) + "..."; }
    }

    public class EngineException : Exception
    {
        public string Detail { get; private set; }
        public EngineException(string message, string detail) : base(message) { Detail = detail ?? ""; }
    }

    /// <summary>A running (or finished) engine script and what its log says so far.</summary>
    public class Worker
    {
        private static readonly Regex LineRx = new Regex(@"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[(\w+)\s*\] (.*)$", RegexOptions.Compiled);
        public string Script { get; private set; }
        public string LogPath { get; set; }
        public Process Process { get; set; }
        public List<string> Lines { get; private set; }
        public StringBuilder Text { get; private set; }
        public string Phase { get; private set; }
        public string LastItem { get; private set; }
        public bool Paused { get; private set; }
        public int Warnings { get; private set; }
        public int Errors { get; private set; }
        public HashSet<string> DoneIds { get; private set; }
        public bool HasExited { get; private set; }
        public int ExitCode { get; private set; }
        public bool StdErr { get; private set; }
        public string StdErrText { get { return _err.ToString(); } }
        private readonly StringBuilder _err = new StringBuilder();
        public event Action Updated;
        public event Action Exited;
        public Worker(string script) { Script = script; Lines = new List<string>(); Text = new StringBuilder(); DoneIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase); }

        public void AddLine(string raw, bool stderr)
        {
            if (stderr) { StdErr = true; _err.AppendLine(raw); Text.AppendLine(raw); Lines.Add(raw); Raise(); return; }
            Lines.Add(raw);
            var m = LineRx.Match(raw);
            if (m.Success)
            {
                var level = m.Groups[1].Value; var msg = m.Groups[2].Value;
                Text.AppendLine(msg);
                if (msg.StartsWith("Phase ")) Phase = msg;
                if (level == "WARN" && !msg.StartsWith("Wait for OneDrive")) Warnings++;
                if (level == "ERROR") Errors++;
                if (level == "OK" || level == "WARN" || level == "ERROR" || level == "WAIT") { var sp = msg.IndexOf(' '); var id = sp > 0 ? msg.Substring(0, sp) : msg; if (id.Length > 2 && id.IndexOf('-') > 0 && !id.EndsWith(":")) { DoneIds.Add(id.TrimEnd(':')); LastItem = id.TrimEnd(':'); } }
                if (msg.StartsWith("PAUSE")) Paused = true; else if (msg.StartsWith("RESUME")) Paused = false;
            }
            else Text.AppendLine(raw);
            Raise();
        }
        public void Finish(int exitCode) { HasExited = true; ExitCode = exitCode; Raise(); var h = Exited; if (h != null) h(); }
        private void Raise() { var h = Updated; if (h != null) h(); }
        public bool Failed { get { return HasExited && (ExitCode != 0 || StdErr); } }
        public void Kill() { try { if (Process != null && !Process.HasExited) Process.Kill(); } catch { } }
    }
}
