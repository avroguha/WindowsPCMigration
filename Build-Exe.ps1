# Builds dist\PCMigration.exe - a single file that carries the whole kit.
# Needs nothing beyond Windows: the C# compiler that ships with .NET Framework (csc.exe) compiles a small launcher
# that embeds the kit as a zip, unpacks it to %LOCALAPPDATA%\PCMigration\kit on every start and runs the wizard.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$files = 'Start Migration.cmd', 'Migration-UI.ps1', 'MigrationCommon.psm1', 'catalog.json', 'Export-Profile.ps1', 'Compare-Software.ps1', 'Import-Profile.ps1', 'Export.cmd', 'Compare-Software.cmd', 'Import.cmd', 'README.md', 'VERSION'
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()   # e.g. 1.1.0 - bump it in the VERSION file
$work = Join-Path $env:TEMP 'PCMigration-build'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $work 'kit') | Out-Null
foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $work 'kit') }
Compress-Archive -Path (Join-Path $work 'kit\*') -DestinationPath (Join-Path $work 'kit.zip')

# icon: blue rounded square with a white arrow (so the exe does not look like a generic blank file)
Add-Type -AssemblyName System.Drawing
$ico = Join-Path $work 'app.ico'
$bmp = New-Object Drawing.Bitmap 64, 64
$g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
$path = New-Object Drawing.Drawing2D.GraphicsPath; $path.AddArc(2, 2, 16, 16, 180, 90); $path.AddArc(46, 2, 16, 16, 270, 90); $path.AddArc(46, 46, 16, 16, 0, 90); $path.AddArc(2, 46, 16, 16, 90, 90); $path.CloseFigure()
$g.FillPath((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(37, 99, 235))), $path)
$pen = New-Object Drawing.Pen ([Drawing.Color]::White), 7; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
$g.DrawLine($pen, 14, 32, 46, 32); $g.DrawLine($pen, 34, 20, 46, 32); $g.DrawLine($pen, 34, 44, 46, 32)
$g.Dispose()
$hIcon = $bmp.GetHicon(); $icon = [Drawing.Icon]::FromHandle($hIcon)
$fs = [IO.File]::Create($ico); $icon.Save($fs); $fs.Dispose()

$cs = @'
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("PC Migration")]
[assembly: AssemblyDescription("Moves a user's settings from one Windows PC to another through OneDrive or a shared folder")]
[assembly: AssemblyProduct("PC Migration")]
[assembly: AssemblyVersion("__VERSION__.0")]
[assembly: AssemblyFileVersion("__VERSION__.0")]
[assembly: AssemblyInformationalVersion("__VERSION__")]

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PCMigration", "kit-__VERSION__");
        try
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
            Directory.CreateDirectory(dir);
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("kit.zip"))
            using (ZipArchive z = new ZipArchive(s, ZipArchiveMode.Read))
                z.ExtractToDirectory(dir);
            // VERSION comes with the kit itself
        }
        catch (Exception e)
        {
            MessageBox.Show("Could not unpack the migration kit to\n" + dir + "\n\n" + e.Message, "PC Migration", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
        string errLog = Path.Combine(dir, "wizard-error.log");
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
            "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + Path.Combine(dir, "Migration-UI.ps1") + "\" " + string.Join(" ", args));
        psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = dir; psi.RedirectStandardError = true;
        try
        {
            using (Process p = Process.Start(psi))
            {
                string err = p.StandardError.ReadToEnd();
                p.WaitForExit();
                if (p.ExitCode != 0 || err.Trim().Length > 0)
                {
                    File.WriteAllText(errLog, err);
                    MessageBox.Show("The wizard did not start or stopped with an error.\n\n" + (err.Length > 1200 ? err.Substring(0, 1200) + "..." : err) +
                        "\n\nIf your company blocks PowerShell scripts, ask IT to allow this folder:\n" + dir, "PC Migration", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return 1;
                }
            }
        }
        catch (Exception e)
        {
            MessageBox.Show("PowerShell could not be started: " + e.Message, "PC Migration", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 3;
        }
        return 0;
    }
}
'@
$cs = $cs.Replace('__VERSION__', $version)
Set-Content -LiteralPath (Join-Path $work 'Launcher.cs') -Value $cs -Encoding UTF8

$fw = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$csc = Join-Path $fw 'csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc" }
$dist = Join-Path $root 'dist'; New-Item -ItemType Directory -Force -Path $dist | Out-Null
Get-ChildItem $dist -Filter 'PCMigration-*.exe' | Remove-Item -Force
$exe = Join-Path $dist "PCMigration-$version.exe"
& $csc /nologo /target:winexe /optimize+ "/out:$exe" "/win32icon:$ico" "/resource:$(Join-Path $work 'kit.zip'),kit.zip" `
    "/r:$fw\System.IO.Compression.dll" "/r:$fw\System.IO.Compression.FileSystem.dll" "/r:$fw\System.Windows.Forms.dll" (Join-Path $work 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
Remove-Item $work -Recurse -Force
"$exe  ($([math]::Round((Get-Item $exe).Length / 1KB)) KB, version $version)"
