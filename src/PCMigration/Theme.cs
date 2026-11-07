using System;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace PCMigration
{
    public enum ThemeMode { System, Light, Dark }

    /// <summary>Follows the Windows theme (light/dark) and the user's accent colour, like a WinUI app does.</summary>
    public static class Theme
    {
        public static ThemeMode Mode { get; private set; } = ThemeMode.System;
        public static bool IsDark { get; private set; }
        public static Color AccentColor { get; private set; } = Color.FromRgb(0x00, 0x5F, 0xB8);
        public static event Action Changed;
        private static ResourceDictionary _colors;

        private static bool _forced;
        public static void Initialize()
        {
            if (!_forced) { try { var s = (string)Registry.GetValue(@"HKEY_CURRENT_USER\Software\PCMigration", "Theme", null); ThemeMode m; if (s != null && Enum.TryParse(s, out m)) Mode = m; } catch { } }
            Apply();
            SystemEvents.UserPreferenceChanged += (s, e) => { if (e.Category == UserPreferenceCategory.General || e.Category == UserPreferenceCategory.Color || e.Category == UserPreferenceCategory.VisualStyle) Application.Current.Dispatcher.BeginInvoke(new Action(Apply)); };
        }
        public static void ForceMode(ThemeMode mode) { Mode = mode; _forced = true; }
        public static void SetMode(ThemeMode mode)
        {
            Mode = mode;
            try { Registry.SetValue(@"HKEY_CURRENT_USER\Software\PCMigration", "Theme", mode.ToString()); } catch { }
            Apply();
        }
        private static bool SystemIsDark()
        {
            try { var v = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1); return v is int && (int)v == 0; } catch { return false; }
        }
        // light3, light2, light1, accent, dark1, dark2, dark3 - Windows keeps the whole palette it derived from the chosen colour
        private static Color[] ReadPalette()
        {
            try
            {
                var b = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent", "AccentPalette", null) as byte[];
                if (b != null && b.Length >= 28) { var c = new Color[7]; for (int i = 0; i < 7; i++) c[i] = Color.FromRgb(b[i * 4], b[i * 4 + 1], b[i * 4 + 2]); return c; }
            }
            catch { }
            Color a = AccentFromDwm();
            return new[] { Mix(a, Colors.White, 0.6), Mix(a, Colors.White, 0.4), Mix(a, Colors.White, 0.2), a, Mix(a, Colors.Black, 0.1), Mix(a, Colors.Black, 0.25), Mix(a, Colors.Black, 0.4) };
        }
        private static Color AccentFromDwm()
        {
            try { var v = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM", "AccentColor", null); if (v is int) { uint abgr = unchecked((uint)(int)v); return Color.FromRgb((byte)(abgr & 0xFF), (byte)((abgr >> 8) & 0xFF), (byte)((abgr >> 16) & 0xFF)); } } catch { }
            return Color.FromRgb(0x00, 0x5F, 0xB8);
        }
        private static Color Mix(Color a, Color b, double t) { return Color.FromRgb((byte)(a.R + (b.R - a.R) * t), (byte)(a.G + (b.G - a.G) * t), (byte)(a.B + (b.B - a.B) * t)); }

        private static void Apply()
        {
            IsDark = Mode == ThemeMode.Dark || (Mode == ThemeMode.System && SystemIsDark());
            var pal = ReadPalette(); AccentColor = pal[3];
            var app = Application.Current; var dicts = app.Resources.MergedDictionaries;
            // the colour dictionary must be LAST: WPF resolves merged dictionaries from the last one backwards
            if (_colors == null) { foreach (var d in dicts) if (d.Source != null && d.Source.OriginalString.EndsWith("Light.xaml")) { _colors = d; break; } }
            if (_colors != null) dicts.Remove(_colors);
            _colors = new ResourceDictionary { Source = new Uri(IsDark ? "Themes/Dark.xaml" : "Themes/Light.xaml", UriKind.Relative) };
            dicts.Add(_colors);
            // accent set: in dark theme Windows uses the lighter accent with dark text, in light theme the base accent with white text
            Color fill = IsDark ? pal[1] : pal[3], hover = IsDark ? pal[2] : pal[4], pressed = IsDark ? pal[3] : pal[5], text = IsDark ? pal[1] : pal[4];
            Set("Accent", fill); Set("AccentHover", hover); Set("AccentPressed", pressed); Set("AccentText", text);
            Set("OnAccent", IsDark ? Color.FromRgb(0, 0, 0) : Colors.White);
            Set("AccentDisabled", IsDark ? Color.FromArgb(0x28, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x37, 0, 0, 0));
            Set("AccentBorder", IsDark ? Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF));
            Set("AccentSoft", IsDark ? Color.FromArgb(0x30, fill.R, fill.G, fill.B) : Color.FromArgb(0x1A, fill.R, fill.G, fill.B));
            var h = Changed; if (h != null) h();
        }
        private static void Set(string key, Color c) { var b = new SolidColorBrush(c); b.Freeze(); Application.Current.Resources[key] = b; }
        public static Brush Brush(string key) { return Application.Current.TryFindResource(key) as Brush; }
    }
}
