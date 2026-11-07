using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace PCMigration
{
    /// <summary>The few Win32 calls the app needs: DWM backdrop and dark title bar, snap-layout hit testing, the modern folder picker.</summary>
    internal static class Native
    {
        [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int index);
        [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hWnd, int index, int value);
        [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

        private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
        private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        private const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
        private const int WM_NCHITTEST = 0x0084, WM_NCLBUTTONDOWN = 0x00A1, WM_NCLBUTTONUP = 0x00A2, WM_NCMOUSELEAVE = 0x02A2;
        private const int HTMAXBUTTON = 9, HTCLIENT = 1;

        public static int OsBuild
        {
            get
            {
                try { using (var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion")) { var v = k?.GetValue("CurrentBuildNumber") as string; int b; if (int.TryParse(v, out b)) return b; } } catch { }
                return Environment.OSVersion.Version.Build;
            }
        }
        public static bool IsWindows11 { get { return OsBuild >= 22000; } }
        public static bool SupportsMica { get { return OsBuild >= 22621; } }

        public static void SetDarkTitleBar(IntPtr hwnd, bool dark)
        {
            int v = dark ? 1 : 0;
            try { DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref v, 4); } catch { }
        }
        public static bool TryEnableMica(IntPtr hwnd, bool enable)
        {
            if (!SupportsMica) return false;
            int v = enable ? 2 : 1;   // 2 = Mica, 1 = none
            try { return DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref v, 4) == 0; } catch { return false; }
        }
        /// <summary>With the DWM frame extended into the client area (needed for Mica), Windows 11 still paints its own caption
        /// buttons under ours. Dropping WS_SYSMENU stops that; minimize/maximize/close are our buttons from then on.</summary>
        public static void RemoveSystemCaptionButtons(IntPtr hwnd)
        {
            try
            {
                const int GWL_STYLE = -16, WS_SYSMENU = 0x80000;
                SetWindowLong(hwnd, GWL_STYLE, GetWindowLong(hwnd, GWL_STYLE) & ~WS_SYSMENU);
                SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, 0x0002 | 0x0001 | 0x0004 | 0x0020);   // NOMOVE | NOSIZE | NOZORDER | FRAMECHANGED
            }
            catch { }
        }
        public static void SetRoundedCorners(IntPtr hwnd)
        {
            if (!IsWindows11) return;
            int v = 2;   // DWMWCP_ROUND
            try { DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref v, 4); } catch { }
        }

        /// <summary>Tells Windows 11 where the Maximize button is so the Snap Layouts flyout appears on hover.</summary>
        public static void HookSnapLayouts(Window window, FrameworkElement maximizeButton, Action onMaximizeClick)
        {
            var src = PresentationSource.FromVisual(window) as HwndSource;
            if (src == null) return;
            bool overButton = false;
            src.AddHook((IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) =>
            {
                if (msg == WM_NCHITTEST)
                {
                    try
                    {
                        int x = (short)(lParam.ToInt64() & 0xFFFF), y = (short)((lParam.ToInt64() >> 16) & 0xFFFF);
                        var pt = maximizeButton.PointFromScreen(new Point(x, y));
                        bool over = pt.X >= 0 && pt.Y >= 0 && pt.X < maximizeButton.ActualWidth && pt.Y < maximizeButton.ActualHeight && maximizeButton.IsVisible;
                        if (over != overButton) { overButton = over; maximizeButton.Opacity = over ? 0.999 : 1; maximizeButton.Tag = over ? "hover" : null; }
                        if (over) { handled = true; return new IntPtr(HTMAXBUTTON); }
                    }
                    catch { }
                }
                else if (msg == WM_NCLBUTTONDOWN && wParam.ToInt32() == HTMAXBUTTON) { handled = true; }
                else if (msg == WM_NCLBUTTONUP && wParam.ToInt32() == HTMAXBUTTON) { handled = true; onMaximizeClick(); }
                else if (msg == WM_NCMOUSELEAVE) { if (overButton) { overButton = false; maximizeButton.Tag = null; } }
                return IntPtr.Zero;
            });
        }

        // ---- modern folder picker (IFileOpenDialog with FOS_PICKFOLDERS) ----
        public static string PickFolder(Window owner, string title, string initial)
        {
            try
            {
                var dlg = (IFileOpenDialog)new FileOpenDialogRCW();
                uint opts; dlg.GetOptions(out opts);
                dlg.SetOptions(opts | 0x20 /*PICKFOLDERS*/ | 0x40 /*FORCEFILESYSTEM*/ | 0x2000 /*NOCHANGEDIR*/);
                dlg.SetTitle(title);
                if (!string.IsNullOrEmpty(initial) && System.IO.Directory.Exists(initial))
                {
                    IShellItem item; var iid = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
                    if (SHCreateItemFromParsingName(initial, IntPtr.Zero, ref iid, out item) == 0) dlg.SetFolder(item);
                }
                var hwnd = owner != null ? new WindowInteropHelper(owner).Handle : IntPtr.Zero;
                if (dlg.Show(hwnd) != 0) return null;
                IShellItem result; dlg.GetResult(out result);
                IntPtr p; result.GetDisplayName(0x80058000 /*FILESYSPATH*/, out p);
                var path = Marshal.PtrToStringUni(p); Marshal.FreeCoTaskMem(p);
                return path;
            }
            catch
            {
                using (var fb = new System.Windows.Forms.FolderBrowserDialog { Description = title, ShowNewFolderButton = true })
                    return fb.ShowDialog() == System.Windows.Forms.DialogResult.OK ? fb.SelectedPath : null;
            }
        }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern int SHCreateItemFromParsingName(string path, IntPtr pbc, ref Guid riid, out IShellItem item);
        [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] private class FileOpenDialogRCW { }
        [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IFileOpenDialog
        {
            [PreserveSig] int Show(IntPtr parent);
            void SetFileTypes(uint n, IntPtr rg); void SetFileTypeIndex(uint i); void GetFileTypeIndex(out uint i);
            void Advise(IntPtr e, out uint c); void Unadvise(uint c);
            void SetOptions(uint o); void GetOptions(out uint o);
            void SetDefaultFolder(IShellItem psi); void SetFolder(IShellItem psi); void GetFolder(out IShellItem psi); void GetCurrentSelection(out IShellItem psi);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string n); void GetFileName(out IntPtr n);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string t); void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string t); void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string t);
            void GetResult(out IShellItem psi); void AddPlace(IShellItem psi, int f); void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string e);
            void Close(int hr); void SetClientGuid(ref Guid g); void ClearClientData(); void SetFilter(IntPtr f);
            void GetResults(out IntPtr r); void GetSelectedItems(out IntPtr r);
        }
        [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItem
        {
            void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv); void GetParent(out IShellItem ppsi);
            void GetDisplayName(uint sigdnName, out IntPtr ppszName); void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs); void Compare(IShellItem psi, uint hint, out int piOrder);
        }
    }
}
