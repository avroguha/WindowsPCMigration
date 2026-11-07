using System;
using System.IO;
using System.Reflection;

namespace PCMigration
{
    /// <summary>The engine (PowerShell scripts + catalog) travels inside the exe and is unpacked next to the user's profile on every start.</summary>
    public static class Kit
    {
        public static string Version { get; private set; }
        public static string Dir { get; private set; }
        public static string BackupRootOverride { get; set; }
        private static readonly string[] Files = { "MigrationCommon.psm1", "catalog.json", "Export-Profile.ps1", "Compare-Software.ps1", "Import-Profile.ps1", "UI-Probe.ps1", "Export.cmd", "Compare-Software.cmd", "Import.cmd", "README.md", "VERSION" };

        public static string LocalAppDir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PCMigration"); } }

        public static void Initialize(string kitOverride)
        {
            var asm = Assembly.GetExecutingAssembly();
            using (var s = asm.GetManifestResourceStream("kit/VERSION")) using (var r = new StreamReader(s)) Version = r.ReadToEnd().Trim();
            if (!string.IsNullOrEmpty(kitOverride) && File.Exists(Path.Combine(kitOverride, "UI-Probe.ps1"))) { Dir = Path.GetFullPath(kitOverride); return; }
            Dir = Path.Combine(LocalAppDir, "kit-" + Version);
            Directory.CreateDirectory(Dir);
            foreach (var f in Files)
            {
                using (var s = asm.GetManifestResourceStream("kit/" + f))
                {
                    if (s == null) continue;
                    var target = Path.Combine(Dir, f);
                    using (var ms = new MemoryStream()) { s.CopyTo(ms); var bytes = ms.ToArray(); if (!File.Exists(target) || !SameBytes(File.ReadAllBytes(target), bytes)) File.WriteAllBytes(target, bytes); }
                }
            }
            // older unpacked kits are not needed any more
            try { foreach (var d in Directory.GetDirectories(LocalAppDir, "kit-*")) if (!string.Equals(d, Dir, StringComparison.OrdinalIgnoreCase)) Directory.Delete(d, true); } catch { }
        }
        private static bool SameBytes(byte[] a, byte[] b) { if (a.Length != b.Length) return false; for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false; return true; }
        public static string Script(string name) { return Path.Combine(Dir, name); }
        public static string LogDir { get { var d = Path.Combine(LocalAppDir, "logs"); Directory.CreateDirectory(d); return d; } }
    }
}
