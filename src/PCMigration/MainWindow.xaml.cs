using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using PCMigration.Pages;

namespace PCMigration
{
    public partial class MainWindow : Window
    {
        public Session Session { get; private set; }
        private AppPage _page;
        private Action _onNext, _onBack;
        private TaskCompletionSource<bool> _dialog;
        private bool _mica;

        public MainWindow()
        {
            InitializeComponent();
            Session = new Session();
            Title = "PC Migration " + Kit.Version;
            VersionText.Text = "Version " + Kit.Version;
            StepsList.ItemsSource = Session.Steps;
            SourceInitialized += (s, e) => InitChrome();
            StateChanged += (s, e) => { Root.Margin = WindowState == WindowState.Maximized ? new Thickness(8) : new Thickness(0); MaxBtn.Content = WindowState == WindowState.Maximized ? "" : ""; };
            Activated += (s, e) => WindowTitle.Foreground = Theme.Brush("TextPrimary");
            Deactivated += (s, e) => WindowTitle.Foreground = Theme.Brush("TitleBarInactive");
            Theme.Changed += ApplyTheme;
            Closing += OnClosing;
            Loaded += async (s, e) => { ApplyTheme(); await RefreshEnvironment(); Navigate(new StartPage()); };
            PreviewKeyDown += (s, e) => { if (e.Key == Key.Escape && DialogLayer.Visibility == Visibility.Visible) { DialogSecondary_Click(null, null); e.Handled = true; } };
        }

        // ---------- window chrome ----------
        private void InitChrome()
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            Native.SetRoundedCorners(hwnd);
            _mica = Native.TryEnableMica(hwnd, true);
            if (_mica)
            {
                var src = HwndSource.FromHwnd(hwnd); if (src != null && src.CompositionTarget != null) src.CompositionTarget.BackgroundColor = Colors.Transparent;
                Background = Brushes.Transparent;
            }
            else Chrome.GlassFrameThickness = Native.IsWindows11 ? new Thickness(-1) : new Thickness(0, 0, 0, 1);
            Native.SetDarkTitleBar(hwnd, Theme.IsDark);
            Native.RemoveSystemCaptionButtons(hwnd);
            Native.HookSnapLayouts(this, MaxBtn, () => MaxBtn_Click(null, null));
        }
        private void ApplyTheme()
        {
            try { Native.SetDarkTitleBar(new WindowInteropHelper(this).Handle, Theme.IsDark); } catch { }
            if (!_mica) Background = Theme.Brush("BgBase");
            ThemeText.Text = Theme.Mode == ThemeMode.System ? "Appearance" : Theme.Mode == ThemeMode.Dark ? "Dark" : "Light";
            if (_page != null) _page.OnThemeChanged();
        }
        private void MinBtn_Click(object sender, RoutedEventArgs e) { WindowState = WindowState.Minimized; }
        private void MaxBtn_Click(object sender, RoutedEventArgs e) { WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized; }
        private void CloseBtn_Click(object sender, RoutedEventArgs e) { Close(); }
        private void ThemeBtn_Click(object sender, RoutedEventArgs e)
        {
            var next = Theme.Mode == ThemeMode.System ? ThemeMode.Light : Theme.Mode == ThemeMode.Light ? ThemeMode.Dark : ThemeMode.System;
            Theme.SetMode(next);
        }
        private void LogsBtn_Click(object sender, RoutedEventArgs e) { Shell.OpenFolder(Kit.LogDir); }
        private async void AboutBtn_Click(object sender, RoutedEventArgs e)
        {
            await Dialog("PC Migration " + Kit.Version,
                "Moves your side of a Windows PC - settings, preferences, the list of installed programs - from an old computer to a new one through OneDrive or a shared folder. " +
                "It runs as a standard user: no administrator rights, nothing installed, nothing touched outside your own profile.\n\n" +
                "Engine files: " + Kit.Dir + "\nLogs: " + Kit.LogDir + "\nWindows build " + Native.OsBuild + (_mica ? ", Mica backdrop" : ""), "Close", null);
        }
        private async void OnClosing(object sender, System.ComponentModel.CancelEventArgs e)
        {
            var w = Session.Worker;
            if (w != null && !w.HasExited)
            {
                e.Cancel = true;
                if (await Dialog("Work is still running", "The " + (Session.Mode == Mode.Export ? "packing" : "restore") + " has not finished. Closing now stops it half way; you can run it again later and it continues where it left off.", "Keep running", "Stop and close") == false)
                { w.Kill(); Session.Worker = null; Close(); }
            }
        }

        // ---------- environment / status pane ----------
        public async Task RefreshEnvironment()
        {
            try
            {
                var env = Environment2.From(await Engine.Probe("environment"));
                Session.Env = env;
                UserText.Text = env.User;
                UserSub.Text = env.Admin ? "Running as administrator - not needed, but fine" : "Standard user - exactly what this needs";
                RootText.Text = string.IsNullOrEmpty(env.BackupRoot) ? "OneDrive not found - choose a folder" : env.BackupRoot;
                RootText.ToolTip = env.BackupRoot;
                NetText.Text = env.NetworkAvailable ? "Network connected" : "No network";
                NetSub.Text = env.OneDriveRunning ? "OneDrive is running" : (string.IsNullOrEmpty(env.OneDrive) ? "OneDrive is not set up here" : "OneDrive is not running");
                NetGlyph.Text = env.NetworkAvailable ? "" : "";
            }
            catch (EngineException ex) { ShowError(ex.Message, "PowerShell could not run the migration engine. If your company blocks PowerShell scripts, ask IT to allow this folder:\n" + Kit.Dir, ex.Detail); }
        }
        private void ChangeRootBtn_Click(object sender, RoutedEventArgs e) { ChangeRoot(); }
        public async void ChangeRoot()
        {
            var picked = Native.PickFolder(this, "Pick a folder that BOTH computers can reach (OneDrive, a network share). A PCMigration folder is created inside it.", Session.Env != null ? Session.Env.BackupRoot : null);
            if (picked == null) return;
            var root = picked.EndsWith("\\PCMigration", StringComparison.OrdinalIgnoreCase) ? picked : System.IO.Path.Combine(picked, "PCMigration");
            try { System.IO.Directory.CreateDirectory(root); } catch (Exception ex) { ShowError("That folder cannot be used", ex.Message, null); return; }
            Kit.BackupRootOverride = root;
            await RefreshEnvironment();
            if (_page != null) _page.OnRootChanged();
        }

        // ---------- navigation ----------
        public void Navigate(AppPage page)
        {
            if (_page != null) _page.OnLeave();
            _page = page; page.Window = this;
            PageHost.Content = page; PageScroller.ScrollToTop();
            ModeLabel.Text = Session.Mode == Mode.Export ? "This is the old computer" : Session.Mode == Mode.Import ? "This is the new computer" : "Move your settings to a new computer";
            if (!string.IsNullOrEmpty(page.StepKey)) Session.GoTo(page.StepKey);
            page.OnShown();
        }
        public void SetHeader(string title, string subtitle) { PageTitle.Text = title; PageSubtitle.Text = subtitle; PageSubtitle.Visibility = string.IsNullOrEmpty(subtitle) ? Visibility.Collapsed : Visibility.Visible; }
        public void SetFooter(string next, bool nextEnabled, bool backEnabled, string note, Action onNext, Action onBack)
        {
            NextBtn.Content = next; NextBtn.IsEnabled = nextEnabled; NextBtn.Visibility = next == null ? Visibility.Collapsed : Visibility.Visible;
            BackBtn.IsEnabled = backEnabled; BackBtn.Visibility = onBack == null ? Visibility.Collapsed : Visibility.Visible;
            FooterNote.Text = note ?? ""; _onNext = onNext; _onBack = onBack;
        }
        public void SetNextEnabled(bool on) { NextBtn.IsEnabled = on; }
        public void SetNote(string note) { FooterNote.Text = note ?? ""; }
        private void NextBtn_Click(object sender, RoutedEventArgs e) { if (_onNext != null) _onNext(); }
        private void BackBtn_Click(object sender, RoutedEventArgs e) { if (_onBack != null) _onBack(); }
        private void Step_Click(object sender, RoutedEventArgs e)
        {
            var key = (string)((FrameworkElement)sender).Tag;
            if (_page != null && _page.StepKey == key) return;
            var page = PageFor(key); if (page != null) Navigate(page);
        }
        public AppPage PageFor(string key)
        {
            switch (key)
            {
                case "start": return new StartPage();
                case "scan": return new ScanPage();
                case "select": return Session.Mode == Mode.Export ? (AppPage)new SelectPage() : new RestoreSelectPage();
                case "review": return new ReviewPage();
                case "run": return new RunPage();
                case "done": return new DonePage();
                case "backup": return new BackupPage();
                case "install": return new InstallPage();
            }
            return null;
        }
        public void GoToStep(string key) { var p = PageFor(key); if (p != null) Navigate(p); }

        // ---------- content dialogs ----------
        /// <summary>Shows a WinUI-style content dialog. Returns true for the primary button, false for the secondary (or Escape).</summary>
        public Task<bool> Dialog(string title, string message, string primary, string secondary, string details = null, UIElement extra = null)
        {
            DialogTitle.Text = title; DialogMessage.Text = message ?? ""; DialogMessage.Visibility = string.IsNullOrEmpty(message) ? Visibility.Collapsed : Visibility.Visible;
            DialogPrimary.Content = primary; DialogSecondary.Content = secondary ?? "";
            DialogSecondary.Visibility = secondary == null ? Visibility.Collapsed : Visibility.Visible;
            Grid.SetColumnSpan(DialogPrimary, secondary == null ? 2 : 1);
            DialogDetails.Text = details ?? ""; DialogDetailsExp.Visibility = string.IsNullOrEmpty(details) ? Visibility.Collapsed : Visibility.Visible; DialogDetailsExp.IsExpanded = false;
            DialogExtra.Content = extra; DialogExtra.Visibility = extra == null ? Visibility.Collapsed : Visibility.Visible;
            DialogLayer.Visibility = Visibility.Visible;
            _dialog = new TaskCompletionSource<bool>();
            DialogPrimary.Focus();
            return _dialog.Task;
        }
        public void ShowError(string title, string message, string details) { var _ = Dialog(title, message, "Close", null, details); }
        private void DialogPrimary_Click(object sender, RoutedEventArgs e) { DialogLayer.Visibility = Visibility.Collapsed; var d = _dialog; _dialog = null; if (d != null) d.TrySetResult(true); }
        private void DialogSecondary_Click(object sender, RoutedEventArgs e) { DialogLayer.Visibility = Visibility.Collapsed; var d = _dialog; _dialog = null; if (d != null) d.TrySetResult(false); }
    }

    /// <summary>Base for every page: a UserControl that gets the window and announces its step.</summary>
    public class AppPage : UserControl
    {
        public MainWindow Window { get; set; }
        public Session Session { get { return Window.Session; } }
        public virtual string StepKey { get { return null; } }
        public virtual void OnShown() { }
        public virtual void OnLeave() { }
        public virtual void OnRootChanged() { }
        public virtual void OnThemeChanged() { }
        public AppPage() { Focusable = false; }
    }
}
