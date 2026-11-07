using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;

namespace PCMigration.Pages
{
    /// <summary>Export step 2: find out what this PC holds before anything is chosen.</summary>
    public partial class ScanPage : AppPage
    {
        public override string StepKey { get { return "scan"; } }
        private bool _running;
        public ScanPage() { InitializeComponent(); ErrorBar.ActionClick += (s, e) => Run(true); OpenBar.ActionClick += (s, e) => { Shell.CloseGracefully(Apps.RunningEditors()); var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(3) }; t.Tick += (s2, e2) => { t.Stop(); RefreshOpen(); }; t.Start(); }; }

        public override void OnShown()
        {
            Window.SetHeader("Scanning this computer", "Programs, settings and data folders that can travel. Nothing is changed and nothing is copied yet.");
            Window.SetFooter("Choose what to take", false, true, "", () => Window.GoToStep("select"), () => Window.GoToStep("start"));
            if (Session.ExportGroups != null) ShowResults(); else Run(false);
        }
        private void RescanBtn_Click(object sender, RoutedEventArgs e) { Session.ExportGroups = null; Session.DiscoveredItems = null; Session.DiscoveryDone = false; Run(true); }

        private async void Run(bool force)
        {
            if (_running) return; _running = true;
            Progress.Visibility = Visibility.Visible; ErrorBar.Visibility = Visibility.Collapsed; Tiles.Visibility = Visibility.Collapsed; GroupsCard.Visibility = Visibility.Collapsed; Window.SetNextEnabled(false);
            ProgressTitle.Text = "Checking programs and settings…"; ProgressSub.Text = "Looking at every entry in the catalog: which programs are here and where they keep their settings.";
            try
            {
                var r = await Engine.Probe("export-scan");
                var groups = new Dictionary<string, SelectionGroup>();
                foreach (var cat in SelectionGroup.Order) groups[cat] = new SelectionGroup(cat, SelectionGroup.TitleFor(cat));
                foreach (var o in Json.Arr(r, "entries"))
                {
                    var cat = Json.Bool(o, "secret") ? "secrets" : Json.Str(o, "category", "tools");
                    if (!groups.ContainsKey(cat)) groups[cat] = new SelectionGroup(cat, SelectionGroup.TitleFor(cat));
                    groups[cat].Add(new SelectionItem { Id = Json.Str(o, "id"), Name = Json.Str(o, "app"), Summary = Json.Str(o, "summary"), Note = Json.Str(o, "notes"), Category = cat, IsSecret = Json.Bool(o, "secret"), IsChecked = !Json.Bool(o, "secret") && !Json.Bool(o, "defaultOff"), SizeMb = Json.NumOrNull(o, "mb"), Badge = Json.Str(o, "badge"), BadgeKind = "info" });
                }
                groups["secrets"].Subtitle = "Private keys, login tokens and saved passwords. Taken only if you tick them, and always encrypted with a password you choose. Often simpler: create new keys on the new computer.";
                groups["custom"].Subtitle = "Anything else that lives outside OneDrive: a folder of API collections, scripts, a project. Restored to the same path on the new PC.";
                groups["discovered"].Subtitle = "Found by looking through AppData. Big folders and folders without a matching program are unticked; tick what you recognise. Caches are left out automatically.";
                if (Session.CustomItems.Count == 0)
                    foreach (var c in Json.Arr(r, "custom")) Session.CustomItems.Add(new SelectionItem { Id = Json.Str(c, "id"), Name = Json.Str(c, "app"), Summary = Json.Str(c, "summary"), Note = Json.Str(c, "notes"), Category = "custom", IsChecked = true, Extra = c });
                foreach (var c in Session.CustomItems) groups["custom"].Add(c);
                Session.ExportGroups = SelectionGroup.Order.Select(k => groups[k]).ToList();
                // sizes stream in while the user reads the page
                var ids = Session.ExportGroups.SelectMany(g => g.Items).Where(i => i.SizeMb == null && i.Category != "custom" && i.Category != "discovered").Select(i => i.Id).ToList();
                var byId = Session.ExportGroups.SelectMany(g => g.Items).ToDictionary(i => i.Id, i => i);
                if (ids.Count > 0) Engine.ProbeSizes(ids, Dispatcher, (id, mb) => { SelectionItem it; if (byId.TryGetValue(id, out it)) it.SizeMb = mb; }, () => { });
                ShowResults();
                ProgressTitle.Text = "Looking for other programs' data folders…"; ProgressSub.Text = "Every AppData folder that no catalog entry covers is measured and matched to an installed program. This is the slow part - usually under a minute.";
                var d = await Engine.Probe("discovered");
                Session.DiscoveredItems = new List<SelectionItem>();
                foreach (var o in Json.Arr(d, "discovered"))
                    Session.DiscoveredItems.Add(new SelectionItem { Id = Json.Str(o, "id"), Name = Json.Str(o, "app"), Summary = Json.Str(o, "summary"), Note = Json.Str(o, "notes"), Category = "discovered", IsChecked = !Json.Bool(o, "defaultOff"), SizeMb = Json.Num(o, "sizeMB"), Extra = o });
                var dg = Session.ExportGroups.First(g => g.Key == "discovered"); dg.Items.Clear(); foreach (var i in Session.DiscoveredItems) dg.Add(i);
                Session.DiscoveryDone = true;
                ShowResults();
            }
            catch (EngineException ex) { Progress.Visibility = Visibility.Collapsed; ErrorBar.Visibility = Visibility.Visible; ErrorBar.Title = ex.Message; ErrorBar.Message = "Details are in the log folder (Logs, bottom left). " + FirstLine(ex.Detail); }
            finally { _running = false; }
        }
        private static string FirstLine(string s) { if (string.IsNullOrEmpty(s)) return ""; var i = s.IndexOf('\n'); return i < 0 ? s : s.Substring(0, i); }

        private void ShowResults()
        {
            var g = Session.ExportGroups; if (g == null) return;
            var all = g.Where(x => x.Key != "secrets" && x.Key != "discovered" && x.Key != "custom").SelectMany(x => x.Items).ToList();
            var pre = all.Count(i => i.IsChecked);
            T1.Text = all.Count.ToString(); T1s.Text = "across " + g.Count(x => x.Items.Count > 0 && x.Key != "secrets" && x.Key != "discovered" && x.Key != "custom") + " groups";
            T2.Text = pre.ToString(); T2s.Text = all.Count - pre > 0 ? (all.Count - pre) + " large or optional ones unticked" : "everything is ticked";
            var disc = g.First(x => x.Key == "discovered").Items;
            T3.Text = Session.DiscoveryDone ? disc.Count.ToString() : "…"; T3s.Text = !Session.DiscoveryDone ? "still looking" : disc.Count == 0 ? "nothing outside the catalog" : Fmt.Mb(disc.Sum(i => i.SizeMb ?? 0)) + " of programs the catalog does not know";
            var sec = g.First(x => x.Key == "secrets").Items;
            T4.Text = sec.Count.ToString(); T4s.Text = "optional, encrypted";
            Tiles.Visibility = Visibility.Visible;
            GroupRows.ItemsSource = g.Where(x => x.Items.Count > 0).Select(x => new { x.Glyph, x.Title, Count = Fmt.Plural(x.Items.Count, "item") }).ToList();
            GroupsCard.Visibility = Visibility.Visible;
            RefreshOpen();
            if (Session.DiscoveryDone) { Progress.Visibility = Visibility.Collapsed; Window.SetNextEnabled(true); }
        }
        private void RefreshOpen()
        {
            var open = Apps.RunningEditors();
            if (open.Count == 0) { OpenBar.Visibility = Visibility.Collapsed; return; }
            OpenBar.Visibility = Visibility.Visible;
            OpenBar.Message = "Open right now: " + string.Join(", ", open.Select(Apps.Friendly).Distinct()) + ". Unsaved tabs and documents travel only once the program has written them to disk - closing it asks you to save and flushes the rest.";
        }
    }
}
