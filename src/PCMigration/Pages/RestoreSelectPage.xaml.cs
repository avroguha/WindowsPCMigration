using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace PCMigration.Pages
{
    /// <summary>Import step 4: tick what to restore.</summary>
    public partial class RestoreSelectPage : AppPage
    {
        public override string StepKey { get { return "select"; } }
        private DispatcherTimer _timer;
        private PasswordBox _pw;
        private List<string> _running = new List<string>();
        public RestoreSelectPage() { InitializeComponent(); ErrorBar.ActionClick += (s, e) => Load(); OpenBar.ActionClick += (s, e) => Shell.CloseGracefully(_running); }

        public override void OnShown()
        {
            if (Session.Backup == null) { Window.GoToStep("backup"); return; }
            Window.SetHeader("What do you want to restore?", "From the backup made on " + Session.Backup.Computer + ". Anything already set up here the way you like can be unticked.");
            Window.SetFooter("Review", false, true, "Anything replaced is backed up first under AppData\\Local\\PCMigration-backup.", Next, () => Window.GoToStep("install"));
            if (Session.ImportGroups != null) Show(); else Load();
            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) }; _timer.Tick += (s, e) => RefreshOpen(); _timer.Start();
        }
        public override void OnLeave() { if (_timer != null) _timer.Stop(); }

        private async void Load()
        {
            LoadingBar.Visibility = Visibility.Visible; ErrorBar.Visibility = Visibility.Collapsed; Toolbar.Visibility = Visibility.Collapsed; Window.SetNextEnabled(false);
            try
            {
                var r = await Engine.Probe("import-scan", "-Source " + Engine.Quote(Session.Backup.Path));
                Session.ImportSecretsEncrypted = Json.Bool(r, "secretsEncrypted");
                var groups = new Dictionary<string, SelectionGroup>();
                foreach (var cat in SelectionGroup.Order) groups[cat] = new SelectionGroup(cat, SelectionGroup.TitleFor(cat));
                foreach (var o in Json.Arr(r, "rows"))
                {
                    var cat = Json.Str(o, "category", "tools"); if (!groups.ContainsKey(cat)) groups[cat] = new SelectionGroup(cat, SelectionGroup.TitleFor(cat));
                    groups[cat].Add(new SelectionItem { Id = Json.Str(o, "id"), Name = Json.Str(o, "app"), Summary = Json.Str(o, "summary"), Note = Json.Str(o, "notes"), Category = cat, IsSecret = Json.Bool(o, "secret"), SizeMb = Json.Num(o, "mb"), State = Json.Str(o, "state"), IsEnabled = Json.Bool(o, "enabled", true), IsChecked = Json.Bool(o, "checked"), Badge = Json.Str(o, "badge"), BadgeKind = Json.Str(o, "badgeKind"), Force = Json.Bool(o, "force") });
                }
                groups["secrets"].Subtitle = Session.ImportSecretsEncrypted ? "Encrypted on the old computer. Enter the password you chose there." : "These were stored unencrypted.";
                Session.ImportGroups = SelectionGroup.Order.Select(k => groups[k]).Where(g => g.Items.Count > 0).ToList();
                Show();
            }
            catch (EngineException ex) { LoadingBar.Visibility = Visibility.Collapsed; ErrorBar.Visibility = Visibility.Visible; ErrorBar.Title = ex.Message; ErrorBar.Message = ex.Detail; }
        }
        private void Show()
        {
            LoadingBar.Visibility = Visibility.Collapsed; Toolbar.Visibility = Visibility.Visible;
            List.SetGroups(Session.ImportGroups, Footer);
            foreach (var g in Session.ImportGroups) g.PropertyChanged += (s, e) => UpdateTotals();
            var all = Session.ImportGroups.SelectMany(g => g.Items).ToList();
            Window.SetHeader("What do you want to restore?", "From the backup made on " + Session.Backup.Computer + ": " + all.Count(i => i.State == "ready") + " ready, " + all.Count(i => i.State == "done") + " restored earlier, " + all.Count(i => i.State == "waiting") + " waiting for a program to be installed. Anything already set up here the way you like can be unticked.");
            UpdateTotals(); RefreshOpen(); Window.SetNextEnabled(true);
        }
        private object Footer(SelectionGroup g)
        {
            if (g.Key == "secrets" && Session.ImportSecretsEncrypted)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal };
                row.Children.Add(new TextBlock { Text = "Password:", Style = (Style)FindResource("Caption"), Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center });
                _pw = new PasswordBox { Width = 260 }; System.Windows.Automation.AutomationProperties.SetName(_pw, "secrets-password"); row.Children.Add(_pw);
                return row;
            }
            return null;
        }
        private void UpdateTotals()
        {
            var items = Session.ImportGroups.SelectMany(g => g.Items).ToList(); var on = items.Where(i => i.IsChecked).ToList();
            Totals.Text = on.Count + " of " + items.Count + " selected  ·  " + Fmt.Mb(on.Sum(i => i.SizeMb ?? 0));
        }
        private void RefreshOpen()
        {
            if (Session.ImportGroups == null) return;
            var ids = Session.ImportGroups.SelectMany(g => g.Items).Select(i => i.Id).ToList();
            _running = Apps.RunningOwners(ids);
            if (_running.Count == 0) { OpenBar.Visibility = Visibility.Collapsed; return; }
            OpenBar.Visibility = Visibility.Visible;
            OpenBar.Message = "Open right now: " + string.Join(", ", _running) + ". Their settings are restored only after they are closed (save your work first).";
        }
        private void Search_TextChanged(object sender, TextChangedEventArgs e) { SearchHint.Visibility = Search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; List.Filter(Search.Text); }
        private void SelectAll_Click(object sender, RoutedEventArgs e) { foreach (var g in Session.ImportGroups) if (g.Key != "secrets") g.IsChecked = true; }
        private void SelectNone_Click(object sender, RoutedEventArgs e) { List.SetAll(false); }
        private async void Next()
        {
            var items = Session.ImportGroups.SelectMany(g => g.Items).Where(i => i.IsChecked).ToList();
            if (items.Count == 0) { await Window.Dialog("Nothing selected", "Tick at least one item to restore.", "OK", null); return; }
            Session.SecretPassword = null;
            if (items.Any(i => i.IsSecret) && Session.ImportSecretsEncrypted)
            {
                if (_pw == null || _pw.Password.Length == 0) { await Window.Dialog("Password needed", "Enter the password of the keys-and-passwords bundle, or untick those items.", "OK", null); return; }
                Session.SecretPassword = _pw.Password;
            }
            Session.SelectedIds = items.Select(i => i.Id).ToList();
            Window.GoToStep("review");
        }
    }
}
