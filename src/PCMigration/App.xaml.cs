using System;
using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace PCMigration
{
    public partial class App : Application
    {
        public static string StartMode;   // --mode export|import (lab tests)
        public static string TestAddFolder;   // --test-add-folder <path>: Add a folder takes this path instead of opening the picker (UI tests)

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            string kit = null, root = null;
            for (int i = 0; i < e.Args.Length; i++)
            {
                var a = e.Args[i].ToLowerInvariant();
                if (a == "--kit" && i + 1 < e.Args.Length) kit = e.Args[++i];
                else if (a == "--root" && i + 1 < e.Args.Length) root = e.Args[++i];
                else if (a == "--mode" && i + 1 < e.Args.Length) StartMode = e.Args[++i];
                else if (a == "--test-add-folder" && i + 1 < e.Args.Length) TestAddFolder = e.Args[++i];
                else if (a == "--theme" && i + 1 < e.Args.Length) { ThemeMode m; if (Enum.TryParse(e.Args[++i], true, out m)) Theme.ForceMode(m); }
            }
            if (!string.IsNullOrEmpty(root)) Kit.BackupRootOverride = root;
            else if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("PCMIG_ROOT"))) Kit.BackupRootOverride = Environment.GetEnvironmentVariable("PCMIG_ROOT");
            DispatcherUnhandledException += OnUnhandled;
            AppDomain.CurrentDomain.UnhandledException += (s, ex) => Engine.Log("fatal: " + ex.ExceptionObject);
            try { Kit.Initialize(kit); }
            catch (Exception ex)
            {
                MessageBox.Show("The migration kit could not be unpacked to\n" + Kit.LocalAppDir + "\n\n" + ex.Message, "PC Migration", MessageBoxButton.OK, MessageBoxImage.Error);
                Shutdown(2); return;
            }
            Theme.Initialize();
            var w = new MainWindow();
            MainWindow = w;
            w.Show();
        }
        private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            Engine.Log("unhandled: " + e.Exception);
            e.Handled = true;
            var w = MainWindow as MainWindow;
            if (w != null) w.ShowError("Something went wrong", e.Exception.Message, e.Exception.ToString());
            else MessageBox.Show(e.Exception.Message, "PC Migration", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }
}
