# Draws app.ico (16/24/32/48/64/256 px, PNG-compressed entries) with System.Drawing - no design tools needed.
# Rounded accent-blue square with a white arrow leaving one screen and entering another.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot 'app.ico'
$sizes = 16, 24, 32, 48, 64, 256
$pngs = @()
foreach ($s in $sizes) {
    $bmp = New-Object Drawing.Bitmap $s, $s
    $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
    $r = [float]($s * 0.22); $m = [float]($s * 0.04)
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc($m, $m, $r * 2, $r * 2, 180, 90); $path.AddArc($s - $m - $r * 2, $m, $r * 2, $r * 2, 270, 90); $path.AddArc($s - $m - $r * 2, $s - $m - $r * 2, $r * 2, $r * 2, 0, 90); $path.AddArc($m, $s - $m - $r * 2, $r * 2, $r * 2, 90, 90); $path.CloseFigure()
    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.PointF]::new(0, 0)), ([Drawing.PointF]::new($s, $s)), ([Drawing.Color]::FromArgb(0, 120, 212)), ([Drawing.Color]::FromArgb(0, 78, 160))
    $g.FillPath($brush, $path)
    $w = [Math]::Max(1.5, $s * 0.11)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), $w; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    # two "screens": left outline, right filled - and an arrow between them
    $sw = $s * 0.26; $sh = $s * 0.34; $y = $s * 0.33
    $g.DrawRectangle($pen, [float]($s * 0.14), [float]$y, [float]$sw, [float]$sh)
    $g.FillRectangle([Drawing.Brushes]::White, [float]($s * 0.60), [float]$y, [float]$sw, [float]$sh)
    $ax1 = $s * 0.42; $ax2 = $s * 0.57; $ay = $s * 0.5
    if ($s -ge 24) { $g.DrawLine($pen, [float]$ax1, [float]$ay, [float]$ax2, [float]$ay); $g.DrawLine($pen, [float]($ax2 - $s * 0.07), [float]($ay - $s * 0.07), [float]$ax2, [float]$ay); $g.DrawLine($pen, [float]($ax2 - $s * 0.07), [float]($ay + $s * 0.07), [float]$ax2, [float]$ay) }
    $g.Dispose()
    $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $pngs += , $ms.ToArray(); $bmp.Dispose()
}
# ICO container: header, one directory entry per image, then the PNG blobs
$fs = [IO.File]::Create($out); $bw = New-Object IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $sz = $sizes[$i]; $b = [byte]$(if ($sz -ge 256) { 0 } else { $sz })
    $bw.Write($b); $bw.Write($b); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Dispose(); $fs.Dispose()
"$out ($((Get-Item $out).Length) bytes)"
