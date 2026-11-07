using System.Collections.Generic;
using System.Linq;

namespace PCMigration
{
    /// <summary>Programs whose running copies matter: editors that hold unsaved work (export) and programs whose settings are being restored (import).</summary>
    public static class Apps
    {
        // process name -> friendly name; these keep unsaved tabs/documents only in memory until closed
        public static readonly Dictionary<string, string> Editors = new Dictionary<string, string>
        {
            { "Postman", "Postman" }, { "MobaXterm", "MobaXterm" }, { "Notepad", "Notepad" }, { "notepad++", "Notepad++" }, { "Code", "VS Code" }, { "WINWORD", "Word" }, { "EXCEL", "Excel" },
            { "POWERPNT", "PowerPoint" }, { "OUTLOOK", "Outlook" }, { "msedge", "Edge" }, { "chrome", "Chrome" }, { "firefox", "Firefox" }
        };
        // process name -> catalog id prefix whose settings it owns
        public static readonly Dictionary<string, string> Owners = new Dictionary<string, string>
        {
            { "Notepad", "win-notepad-tabs" }, { "msedge", "browser-edge" }, { "chrome", "browser-chrome" }, { "firefox", "browser-firefox" }, { "opera", "browser-opera" }, { "Code", "dev-vscode" }, { "Cursor", "dev-cursor" },
            { "notepad++", "dev-notepadpp" }, { "OUTLOOK", "office-" }, { "EXCEL", "office-" }, { "WINWORD", "office-" }, { "POWERPNT", "office-" }, { "ONENOTE", "office-" }, { "putty", "tools-putty" }, { "WinSCP", "tools-winscp" },
            { "MobaXterm", "tools-mobaxterm" }, { "SecureCRT", "tools-securecrt" }, { "Xshell", "tools-xshell" }, { "WindowsTerminal", "dev-windows-terminal" }, { "dbeaver", "data-dbeaver" }, { "Ssms", "data-ssms" }, { "idea64", "dev-jetbrains" },
            { "pycharm64", "dev-jetbrains" }, { "devenv", "dev-visualstudio" }, { "PowerToys", "tools-powertoys" }, { "Postman", "data-postman" }, { "PBIDesktop", "data-power-bi" }, { "KeePass", "tools-keepass" }, { "claude", "dev-claude-desktop" }
        };
        public static List<string> RunningEditors() { return Shell.Running(Editors.Keys); }
        public static string Friendly(string proc) { string n; return Editors.TryGetValue(proc, out n) ? n : proc; }
        /// <summary>Running programs that own one of the given ids.</summary>
        public static List<string> RunningOwners(IEnumerable<string> ids)
        {
            var list = ids.ToList();
            return Shell.Running(Owners.Keys).Where(p => list.Any(id => id.StartsWith(Owners[p], System.StringComparison.OrdinalIgnoreCase))).ToList();
        }
        public static List<string> IdsBlockedBy(IEnumerable<string> running, IEnumerable<string> ids)
        {
            var r = running.ToList();
            return ids.Where(id => r.Any(p => id.StartsWith(Owners[p], System.StringComparison.OrdinalIgnoreCase))).ToList();
        }
    }
}
