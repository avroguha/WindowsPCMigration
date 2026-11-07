using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;

namespace PCMigration
{
    public class Observable : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        protected bool Set<T>(ref T field, T value, [CallerMemberName] string name = null)
        {
            if (EqualityComparer<T>.Default.Equals(field, value)) return false;
            field = value; Raise(name); return true;
        }
        protected void Raise(string name) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(name)); }
    }

    public static class Fmt
    {
        public static string Mb(double? mb)
        {
            if (mb == null) return "";
            double v = mb.Value;
            if (v < 0.05) return "< 1 MB";
            if (v < 1) return string.Format(CultureInfo.InvariantCulture, "{0:N0} KB", v * 1024);
            if (v < 1024) return string.Format(CultureInfo.InvariantCulture, "{0:N0} MB", v);
            return string.Format(CultureInfo.InvariantCulture, "{0:N1} GB", v / 1024);
        }
        public static string Plural(int n, string one, string many = null) { return n + " " + (n == 1 ? one : (many ?? one + "s")); }
        public static string When(DateTime? t) { return t == null ? "" : t.Value.ToString("d MMM yyyy HH:mm"); }
    }

    /// <summary>One thing that can be packed or restored (a catalog entry, a discovered folder, a folder the user added).</summary>
    public class SelectionItem : Observable
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Summary { get; set; }
        public string Note { get; set; }
        public string Category { get; set; }
        public bool IsSecret { get; set; }
        public bool Force { get; set; }
        public string State { get; set; }       // ready | waiting | done | skipped (restore)
        public object Extra { get; set; }       // the extra-entry definition (discovered / custom) that travels with the backup
        private bool _checked; public bool IsChecked { get { return _checked; } set { if (Set(ref _checked, value)) { if (Group != null) Group.ChildChanged(); } } }
        private bool _enabled = true; public bool IsEnabled { get { return _enabled; } set { Set(ref _enabled, value); } }
        private double? _mb; public double? SizeMb { get { return _mb; } set { if (Set(ref _mb, value)) { Raise("SizeText"); if (Group != null) Group.ChildChanged(); } } }
        public string SizeText { get { return Fmt.Mb(_mb); } }
        private string _badge; public string Badge { get { return _badge; } set { if (Set(ref _badge, value)) Raise("HasBadge"); } }
        public bool HasBadge { get { return !string.IsNullOrEmpty(_badge); } }
        public string BadgeKind { get; set; }   // info | success | warning
        private bool _visible = true; public bool IsVisible { get { return _visible; } set { Set(ref _visible, value); } }
        public SelectionGroup Group { get; set; }
        public string Glyph { get { return SelectionGroup.GlyphFor(Category); } }
    }

    public class SelectionGroup : Observable
    {
        public string Key { get; set; }
        public string Title { get; set; }
        public string Subtitle { get; set; }
        public ObservableCollection<SelectionItem> Items { get; private set; }
        private bool _busy;
        public SelectionGroup(string key, string title, string subtitle = "") { Key = key; Title = title; Subtitle = subtitle; Items = new ObservableCollection<SelectionItem>(); }
        public void Add(SelectionItem i) { i.Group = this; Items.Add(i); }
        public bool? IsChecked
        {
            get { var on = Items.Count(i => i.IsChecked && i.IsEnabled); var all = Items.Count(i => i.IsEnabled); return all == 0 ? (bool?)false : on == 0 ? false : on == all ? true : (bool?)null; }
            set { if (_busy) return; _busy = true; foreach (var i in Items) if (i.IsEnabled) i.IsChecked = value == true; _busy = false; Raise("IsChecked"); Raise("Summary"); }
        }
        public void ChildChanged() { if (!_busy) { Raise("IsChecked"); Raise("Summary"); } }
        public string Summary { get { var on = Items.Where(i => i.IsChecked).ToList(); var mb = on.Sum(i => i.SizeMb ?? 0); return on.Count + " of " + Items.Count + " selected" + (mb > 0.05 ? "  ·  " + Fmt.Mb(mb) : ""); } }
        private bool _visible = true; public bool IsVisible { get { return _visible; } set { Set(ref _visible, value); } }
        public string Glyph { get { return GlyphFor(Key); } }
        public static string GlyphFor(string category)
        {
            switch (category)
            {
                case "windows": return "";
                case "office": return "";
                case "browser": return "";
                case "dev": return "";
                case "tools": return "";
                case "data": return "";
                case "comms": return "";
                case "discovered": return "";
                case "custom": return "";
                case "secrets": return "";
                default: return "";
            }
        }
        public static readonly string[] Order = { "windows", "office", "browser", "dev", "tools", "data", "comms", "discovered", "custom", "secrets" };
        public static string TitleFor(string category)
        {
            switch (category)
            {
                case "windows": return "Windows look, feel and input";
                case "office": return "Microsoft Office and Outlook";
                case "browser": return "Browsers";
                case "dev": return "Developer tools";
                case "tools": return "Utilities";
                case "data": return "Data and database tools";
                case "comms": return "Mail, chat and meetings";
                case "discovered": return "Other programs found on this PC";
                case "custom": return "Folders you added";
                case "secrets": return "Keys and passwords";
                default: return category;
            }
        }
    }

    /// <summary>A row on the "What to install" checklist (from install-items.json + install-state-&lt;pc&gt;.json).</summary>
    public class InstallItem : Observable
    {
        public string Key { get; set; }
        public string Kind { get; set; }
        public string Name { get; set; }
        public string Detail { get; set; }
        public string OldVersion { get; set; }
        public string HereVersion { get; set; }
        public string Link { get; set; }
        public string Command { get; set; }
        public bool Detected { get; set; }
        public string Hint { get; set; }
        private string _status = "pending"; public string Status { get { return _status; } set { if (Set(ref _status, value)) { Raise("IsPending"); Raise("StatusText"); Raise("Glyph"); } } }
        public string By { get; set; }
        public string At { get; set; }
        public bool IsPending { get { return _status == "pending"; } }
        public bool HasLink { get { return !string.IsNullOrEmpty(Link); } }
        public bool HasCommand { get { return !string.IsNullOrEmpty(Command); } }
        public bool CanCopy { get { return Kind == "program" || Kind == "store" || Kind == "portable" || Kind == "tool"; } }
        public string StatusText { get { return _status == "installed" ? "Installed" : _status == "skipped" ? "Skipped" : ""; } }
        public string Glyph { get { return _status == "installed" ? "" : _status == "skipped" ? "" : ""; } }
        public string VersionText
        {
            get
            {
                if (!string.IsNullOrEmpty(OldVersion) && !string.IsNullOrEmpty(HereVersion)) return OldVersion == HereVersion ? "version " + OldVersion : "old PC " + OldVersion + "  →  here " + HereVersion;
                if (!string.IsNullOrEmpty(OldVersion)) return "old PC " + OldVersion;
                if (!string.IsNullOrEmpty(HereVersion)) return "here " + HereVersion;
                return "";
            }
        }
        public string SubText { get { return string.Join("   ·   ", new[] { VersionText, Detail, Hint }.Where(s => !string.IsNullOrEmpty(s))); } }
        public static readonly string[] KindOrder = { "program", "store", "portable", "tool", "vscode-ext", "browser-ext", "npm", "pip", "dotnet-tool", "ps-module" };
        public static string KindTitle(string kind)
        {
            switch (kind)
            {
                case "program": return "Programs (company portal or installer)";
                case "store": return "Microsoft Store apps";
                case "portable": return "Programs that had no installer";
                case "tool": return "Developer tools (Java, Node, Python, .NET, Git...)";
                case "vscode-ext": return "VS Code extensions";
                case "browser-ext": return "Browser extensions";
                case "npm": return "npm global packages";
                case "pip": return "Python packages (pip --user)";
                case "dotnet-tool": return ".NET global tools";
                case "ps-module": return "PowerShell modules";
                default: return kind;
            }
        }
    }
    public class InstallGroup
    {
        public string Kind { get; set; }
        public string Title { get { return InstallItem.KindTitle(Kind); } }
        public List<InstallItem> Pending { get; set; }
        public List<InstallItem> Done { get; set; }
        public int Total { get { return Pending.Count + Done.Count; } }
        public string Progress { get { return Done.Count + " of " + Total + " done"; } }
        public bool HasDone { get { return Done.Count > 0; } }
        public bool HasPending { get { return Pending.Count > 0; } }
        public bool AllDone { get { return Pending.Count == 0; } }
        public bool ExpandDone { get { return Pending.Count == 0 && Done.Count <= 8; } }
        public int InstallableCount { get { return Pending.Count(i => i.HasCommand); } }
        public bool CanInstallAll { get { return InstallableCount > 1; } }
        public string InstallAllText { get { return "Install all " + InstallableCount + " missing now"; } }
        public string DoneHeader { get { return Fmt.Plural(Done.Count, "item") + " installed or skipped"; } }
    }

    /// <summary>A backup folder under the backup root, as described by its manifest.</summary>
    public class BackupInfo
    {
        public string Path { get; set; }
        public string Name { get; set; }
        public string Computer { get; set; }
        public string User { get; set; }
        public DateTime? Created { get; set; }
        public int Packages { get; set; }
        public int Secrets { get; set; }
        public bool SecretsEncrypted { get; set; }
        public double Mb { get; set; }
        public string KitVersion { get; set; }
        public bool NewerThanThisKit { get; set; }
        public int Placeholders { get; set; }
        public bool MadeHere { get; set; }
        public bool ChecklistExists { get; set; }
        public int ChecklistInstalled { get; set; }
        public int ChecklistSkipped { get; set; }
        public int Restored { get; set; }
        public int Deferred { get; set; }
        public bool HasReport { get; set; }
        public bool HasExtensions { get; set; }
        public string Title { get { return Computer + "  ·  " + User; } }
        public string Sub { get { return Fmt.When(Created) + "  ·  " + Fmt.Plural(Packages + Secrets, "item") + "  ·  " + Fmt.Mb(Mb) + (MadeHere ? "  ·  made on this computer" : ""); } }
        public bool InProgress { get { return ChecklistExists || Restored > 0 || Deferred > 0; } }
        public static BackupInfo From(object o)
        {
            return new BackupInfo
            {
                Path = Json.Str(o, "path"), Name = Json.Str(o, "name"), Computer = Json.Str(o, "computer"), User = Json.Str(o, "user"), Created = Json.Date(o, "createdAt"),
                Packages = (int)Json.Num(o, "packages"), Secrets = (int)Json.Num(o, "secrets"), SecretsEncrypted = Json.Bool(o, "secretsEncrypted"), Mb = Json.Num(o, "bytes") / 1048576.0,
                KitVersion = Json.Str(o, "kitVersion"), NewerThanThisKit = Json.Bool(o, "newerThanThisKit"), Placeholders = (int)Json.Num(o, "placeholders"), MadeHere = Json.Bool(o, "madeHere"),
                ChecklistExists = Json.Bool(o, "checklistExists"), ChecklistInstalled = (int)Json.Num(o, "checklistInstalled"), ChecklistSkipped = (int)Json.Num(o, "checklistSkipped"),
                Restored = (int)Json.Num(o, "restored"), Deferred = (int)Json.Num(o, "deferred"), HasReport = Json.Bool(o, "hasReport"), HasExtensions = Json.Bool(o, "hasExtensions")
            };
        }
    }

    public class Environment2
    {
        public string Computer, User, KitVersion, OneDrive, BackupRoot, NetworkText, Os;
        public bool Admin, BackupRootExists, RootFromEnv, NetworkAvailable, OneDriveRunning;
        public List<string> Profiles = new List<string>();
        public static Environment2 From(Dictionary<string, object> o)
        {
            var e = new Environment2
            {
                Computer = Json.Str(o, "computer"), User = Json.Str(o, "user"), KitVersion = Json.Str(o, "kitVersion"), OneDrive = Json.Str(o, "oneDrive"), BackupRoot = Json.Str(o, "backupRoot"),
                Admin = Json.Bool(o, "admin"), BackupRootExists = Json.Bool(o, "backupRootExists"), RootFromEnv = Json.Bool(o, "rootFromEnv"), NetworkAvailable = Json.Bool(o, "networkAvailable"), OneDriveRunning = Json.Bool(o, "oneDriveRunning"), Os = Json.Str(o, "os")
            };
            foreach (var p in Json.Arr(o, "networkProfiles")) e.Profiles.Add(Convert.ToString(p));
            return e;
        }
    }

    /// <summary>Reads the human parts of the engine's reports (report.md manual steps, import-*.md result table).</summary>
    public static class Reports
    {
        public static List<string> ManualSteps(string reportPath)
        {
            var o = new List<string>();
            if (!File.Exists(reportPath)) return o;
            bool inSection = false;
            foreach (var l in File.ReadAllLines(reportPath))
            {
                if (l.StartsWith("## Manual steps")) { inSection = true; continue; }
                if (inSection && l.StartsWith("## ")) break;
                if (inSection && l.StartsWith("- ")) o.Add(l.Substring(2).Replace("**", "").Replace("`", ""));
            }
            return o;
        }
        public static string LatestImportReport(string source)
        {
            try { return Directory.GetFiles(source, "import-" + Environment.MachineName + "-*.md").OrderByDescending(f => File.GetLastWriteTime(f)).FirstOrDefault(); } catch { return null; }
        }
        public static void ImportResults(string reportPath, out int ok, out int bad, out List<string> waiting)
        {
            ok = 0; bad = 0; waiting = new List<string>();
            if (reportPath == null || !File.Exists(reportPath)) return;
            var row = new System.Text.RegularExpressions.Regex(@"^\|\s*`([^`]+)`\s*\|\s*(\w[\w-]*)\s*\|\s*(.*?)\s*\|");
            foreach (var l in File.ReadAllLines(reportPath))
            {
                var m = row.Match(l); if (!m.Success) continue;
                var st = m.Groups[2].Value;
                if (st == "ok") ok++; else if (st == "partial" || st == "failed" || st == "missing") bad++;
                else if (st == "deferred") { var w = System.Text.RegularExpressions.Regex.Match(m.Groups[3].Value, @"waiting for (.+?) to be installed"); if (w.Success && !waiting.Contains(w.Groups[1].Value)) waiting.Add(w.Groups[1].Value); }
            }
        }
    }
}
