using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace PCMigration.Pages
{
    /// <summary>Export step 3: tick what to take.</summary>
    public partial class SelectPage : AppPage
    {
        public override string StepKey { get { return "select"; } }
        private DispatcherTimer _timer;
        private PasswordBox _pw1, _pw2;

        public SelectPage()
        {
            InitializeComponent();
            OpenBar.ActionClick += (s, e) => { Shell.CloseGracefully(Apps.RunningEditors()); };
        }
        public override void OnShown()
        {
            Window.SetHeader("What do you want to take?", "Only things found on this computer are listed. Untick anything you do not need - sizes fill in as they are measured.");
            Window.SetFooter("Review", true, true, "Nothing is changed on this computer.", Next, () => Window.GoToStep("scan"));
            if (Session.ExportGroups == null) { Window.GoToStep("scan"); return; }
            List.SetGroups(Session.ExportGroups, Footer);
            foreach (var g in Session.ExportGroups) { g.PropertyChanged += (s, e) => UpdateTotals(); }
            UpdateTotals(); RefreshOpen();
            DiscoveryBar.Visibility = Session.DiscoveryDone ? Visibility.Collapsed : Visibility.Visible;
            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
            _timer.Tick += (s, e) => { RefreshOpen(); if (Session.DiscoveryDone && DiscoveryBar.Visibility == Visibility.Visible) { DiscoveryBar.Visibility = Visibility.Collapsed; List.SetGroups(Session.ExportGroups, Footer); UpdateTotals(); } };
            _timer.Start();
        }
        public override void OnLeave() { if (_timer != null) _timer.Stop(); }

        private object Footer(SelectionGroup g)
        {
            if (g.Key == "secrets")
            {
                var sp = new StackPanel();
                sp.Children.Add(new TextBlock { Text = "Password for the encrypted bundle (you will need it on the new computer):", Style = (Style)FindResource("Caption"), Margin = new Thickness(0, 4, 0, 6) });
                var row = new StackPanel { Orientation = Orientation.Horizontal };
                _pw1 = new PasswordBox { Width = 240 }; _pw2 = new PasswordBox { Width = 240, Margin = new Thickness(8, 0, 0, 0) };
                System.Windows.Automation.AutomationProperties.SetName(_pw1, "secrets-password"); System.Windows.Automation.AutomationProperties.SetName(_pw2, "secrets-password-repeat");
                row.Children.Add(_pw1); row.Children.Add(new TextBlock { Text = "repeat", Style = (Style)FindResource("Caption"), Margin = new Thickness(12, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center }); row.Children.Add(_pw2);
                sp.Children.Add(row);
                return sp;
            }
            if (g.Key == "custom")
            {
                var sp = new StackPanel();
                if (g.Items.Count == 0) sp.Children.Add(new TextBlock { Text = "No folders added yet.", Style = (Style)FindResource("Caption"), Margin = new Thickness(0, 0, 0, 8) });
                var btn = new Button { HorizontalAlignment = HorizontalAlignment.Left };
                var row = new StackPanel { Orientation = Orientation.Horizontal };
                row.Children.Add(new TextBlock { Text = "", Style = (Style)FindResource("Icon"), FontSize = 14, Margin = new Thickness(0, 0, 8, 0) });
                row.Children.Add(new TextBlock { Text = "Add a folder…" });
                btn.Content = row; System.Windows.Automation.AutomationProperties.SetName(btn, "Add a folder (group)");
                btn.Click += AddFolder_Click;
                sp.Children.Add(btn);
                return sp;
            }
            return null;
        }
        private void UpdateTotals()
        {
            var items = Session.ExportGroups.SelectMany(g => g.Items).ToList();
            var on = items.Where(i => i.IsChecked).ToList();
            Totals.Text = on.Count + " of " + items.Count + " selected  ·  " + (on.Any(i => i.SizeMb == null) ? "measuring… " : "") + Fmt.Mb(on.Sum(i => i.SizeMb ?? 0));
            Window.SetFooterSummary(Fmt.Plural(on.Count, "item") + "  ·  " + Fmt.Mb(on.Sum(i => i.SizeMb ?? 0)) + (on.Any(i => i.SizeMb == null) ? "+" : ""));
        }
        private void RefreshOpen()
        {
            var open = Apps.RunningEditors();
            if (open.Count == 0) { OpenBar.Visibility = Visibility.Collapsed; return; }
            OpenBar.Visibility = Visibility.Visible;
            OpenBar.Message = "Open right now: " + string.Join(", ", open.Select(Apps.Friendly).Distinct()) + ". Their unsaved work and locked files cannot be packed until they are closed.";
        }
        private void Search_TextChanged(object sender, TextChangedEventArgs e) { SearchHint.Visibility = Search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; List.Filter(Search.Text); }
        private void SelectAll_Click(object sender, RoutedEventArgs e) { foreach (var g in Session.ExportGroups) if (g.Key != "secrets") g.IsChecked = true; }
        private void SelectNone_Click(object sender, RoutedEventArgs e) { List.SetAll(false); }
        private async void AddFolder_Click(object sender, RoutedEventArgs e)
        {
            var path = Native.PickFolder(Window, "Pick a folder to carry to the new PC (it is restored to the same path there)", null);
            if (path == null) return;
            path = path.TrimEnd('\\');
            if (Session.CustomItems.Any(c => string.Equals(((IList<object>)Json.Arr(c.Extra, "paths"))[0] as string, path, StringComparison.OrdinalIgnoreCase))) return;
            double mb = 0; try { var r = await Engine.Probe("dirstats", "-Path " + Engine.Quote(path)); mb = Json.Num(r, "mb"); } catch { }
            var n = Session.CustomItems.Count + 1;
            var slug = System.Text.RegularExpressions.Regex.Replace(path, "[^A-Za-z0-9]+", "-").Trim('-').ToLowerInvariant(); if (slug.Length > 40) slug = slug.Substring(0, 40);
            var def = new Dictionary<string, object>
            {
                { "id", "custom-" + n + "-" + slug }, { "app", System.IO.Path.GetFileName(path) }, { "category", "custom" }, { "kind", "files" }, { "paths", new[] { path } },
                { "excludeDirs", new[] { "node_modules", ".git", ".venv", "__pycache__" } }, { "summary", path + "  (" + Fmt.Mb(mb) + ")" }, { "notes", "Folder you added; restored to the same path (adjusted if the username differs)." }
            };
            var item = new SelectionItem { Id = (string)def["id"], Name = (string)def["app"], Summary = (string)def["summary"], Note = (string)def["notes"], Category = "custom", IsChecked = true, SizeMb = mb, Extra = def };
            Session.CustomItems.Add(item);
            Session.ExportGroups.First(g => g.Key == "custom").Add(item);
            List.SetGroups(Session.ExportGroups, Footer); UpdateTotals();
        }
        private async void Next()
        {
            var ids = Session.ExportGroups.SelectMany(g => g.Items).Where(i => i.IsChecked).Select(i => i.Id).ToList();
            if (ids.Count == 0) { await Window.Dialog("Nothing selected", "Tick at least one item to take.", "OK", null); return; }
            var secrets = Session.ExportGroups.First(g => g.Key == "secrets").Items.Where(i => i.IsChecked).ToList();
            Session.SecretPassword = null;
            if (secrets.Count > 0)
            {
                if (_pw1 == null || _pw1.Password.Length == 0) { await Window.Dialog("Password needed", "Enter a password for the keys-and-passwords bundle, or untick those items. Without a password they would be stored in clear in OneDrive.", "OK", null); return; }
                if (_pw1.Password != _pw2.Password) { await Window.Dialog("Passwords differ", "The two passwords do not match.", "OK", null); return; }
                Session.SecretPassword = _pw1.Password;
            }
            Session.SelectedIds = ids;
            Window.GoToStep("review");
        }
    }
}
