using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;

namespace PCMigration.Pages
{
    /// <summary>Import step 3: the checklist of what to install before settings can land.</summary>
    public partial class InstallPage : AppPage
    {
        public override string StepKey { get { return "install"; } }
        private Worker _compare;
        private string StatePath { get { return Path.Combine(Session.Backup.Path, "install-state-" + Environment.MachineName + ".json"); } }
        public InstallPage() { InitializeComponent(); ErrorBar.ActionClick += (s, e) => Compare(); }

        public override void OnShown()
        {
            if (Session.Backup == null) { Window.GoToStep("backup"); return; }
            Window.SetHeader("What to install on this computer", "Everything the old computer had that this one does not. Install from the company portal or the links, then press Installed - or Skip what you no longer need. Skipped programs keep their settings out of the restore. The list remembers itself if you close this app.");
            Window.SetFooter("Next", false, true, "Items still to do can be installed later - run PC Migration again and it continues here.", () => Window.GoToStep("select"), () => Window.GoToStep("backup"));
            if (Session.InstallItems != null) Show(); else Compare();
        }
        public override void OnLeave() { if (_compare != null && !_compare.HasExited) { } }

        private void Compare()
        {
            LoadingBar.Visibility = Visibility.Visible; ErrorBar.Visibility = Visibility.Collapsed; Tiles.Visibility = Visibility.Collapsed; Toolbar.Visibility = Visibility.Collapsed; Groups.ItemsSource = null; Window.SetNextEnabled(false);
            _compare = Engine.Start("Compare-Software.ps1", "-Source " + Engine.Quote(Session.Backup.Path), null, Dispatcher);
            _compare.Exited += () =>
            {
                var itemsFile = Path.Combine(Session.Backup.Path, "install-items.json");
                if (_compare.Failed || !File.Exists(itemsFile)) { LoadingBar.Visibility = Visibility.Collapsed; ErrorBar.Visibility = Visibility.Visible; ErrorBar.Title = "The comparison did not finish"; ErrorBar.Message = (_compare.StdErr ? _compare.StdErrText.Trim() : "No install-items.json was written.") + " Log: " + _compare.LogPath; Window.SetNextEnabled(true); return; }
                Load(itemsFile); Show();
            };
        }
        private void Load(string itemsFile)
        {
            var j = Json.ParseObject(File.ReadAllText(itemsFile));
            var state = new Dictionary<string, object>();
            if (File.Exists(StatePath)) { try { state = Json.Obj(Json.ParseObject(File.ReadAllText(StatePath)), "items") ?? state; } catch { } }
            var list = new List<InstallItem>(); bool changed = false;
            foreach (var o in Json.Arr(j, "items"))
            {
                var it = new InstallItem { Key = Json.Str(o, "key"), Kind = Json.Str(o, "kind"), Name = Json.Str(o, "name"), Detail = Json.Str(o, "detail"), OldVersion = Json.Str(o, "oldVersion"), HereVersion = Json.Str(o, "hereVersion"), Link = Json.Str(o, "link"), Command = Json.Str(o, "command"), Detected = Json.Bool(o, "installed"), Hint = Json.Str(o, "hint") };
                var cur = Json.Obj(state, it.Key);
                if (it.Detected && (cur == null || Json.Str(cur, "status") != "installed")) { it.Status = "installed"; it.By = "auto"; it.At = DateTime.Now.ToString("o"); changed = true; }
                else if (cur == null) { it.Status = "pending"; changed = true; }
                else { it.Status = Json.Str(cur, "status", "pending"); it.By = Json.Str(cur, "by"); it.At = Json.Str(cur, "at"); }
                list.Add(it);
            }
            Session.InstallItems = list;
            if (changed) Save();
        }
        private void Save()
        {
            var items = new Dictionary<string, object>();
            foreach (var it in Session.InstallItems) items[it.Key] = new Dictionary<string, object> { { "status", it.Status }, { "at", it.At ?? "" }, { "by", it.By ?? "" } };
            File.WriteAllText(StatePath, Json.Serialize(new Dictionary<string, object> { { "computer", Environment.MachineName }, { "updatedAt", DateTime.Now.ToString("o") }, { "items", items } }), System.Text.Encoding.UTF8);
        }
        private void Show()
        {
            LoadingBar.Visibility = Visibility.Collapsed; Tiles.Visibility = Visibility.Visible; Toolbar.Visibility = Visibility.Visible;
            var all = Session.InstallItems;
            int inst = all.Count(i => i.Status == "installed"), skip = all.Count(i => i.Status == "skipped"), todo = all.Count - inst - skip;
            T1.Text = inst.ToString(); T2.Text = todo.ToString(); T3.Text = skip.ToString();
            Groups.ItemsSource = InstallItem.KindOrder.Where(k => all.Any(i => i.Kind == k)).Select(k => new InstallGroup { Kind = k, Pending = all.Where(i => i.Kind == k && i.IsPending).ToList(), Done = all.Where(i => i.Kind == k && !i.IsPending).ToList() }).ToList();
            Window.SetNextEnabled(true);
            Window.SetNote(todo == 0 ? "Nothing left on the list. Press Next to choose what to restore." : "Press Next to restore settings now; items still to do can be installed later - run PC Migration again and it continues here.");
        }
        private InstallItem Item(object sender) { return (InstallItem)((FrameworkElement)sender).Tag; }
        private void SetStatus(InstallItem it, string status, string by) { it.Status = status; it.By = by; it.At = status == "pending" ? "" : DateTime.Now.ToString("o"); Save(); Show(); }
        private void Installed_Click(object sender, RoutedEventArgs e) { SetStatus(Item(sender), "installed", "user"); }
        private void Skip_Click(object sender, RoutedEventArgs e) { SetStatus(Item(sender), "skipped", "user"); }
        private void Undo_Click(object sender, RoutedEventArgs e) { SetStatus(Item(sender), "pending", ""); }
        private void Open_Click(object sender, RoutedEventArgs e) { Shell.Open(Item(sender).Link); }
        private void InstallNow_Click(object sender, RoutedEventArgs e) { Shell.RunInPowerShell(Item(sender).Command); }
        private void Copy_Click(object sender, RoutedEventArgs e) { try { Clipboard.SetText(Item(sender).Name); } catch { } }
        private void InstallAll_Click(object sender, RoutedEventArgs e) { var g = (InstallGroup)((FrameworkElement)sender).Tag; Shell.RunInPowerShell(string.Join("; ", g.Pending.Where(i => i.HasCommand).Select(i => i.Command).Concat(new[] { "Write-Host ''; Write-Host 'Done - press Check again in PC Migration' -ForegroundColor Green" }))); }
        private void Recheck_Click(object sender, RoutedEventArgs e) { Compare(); }
        private void OpenList_Click(object sender, RoutedEventArgs e) { Shell.Open(Path.Combine(Session.Backup.Path, "install-list.md")); }
        private async void CopyTodo_Click(object sender, RoutedEventArgs e)
        {
            var lines = Session.InstallItems.Where(i => i.IsPending).Select(i => i.Kind + ": " + i.Name + " " + i.OldVersion + " " + i.Detail).ToList();
            try { Clipboard.SetText(string.Join("\r\n", lines)); } catch { }
            await Window.Dialog("Copied", Fmt.Plural(lines.Count, "item") + " copied to the clipboard.", "OK", null);
        }
    }
}
