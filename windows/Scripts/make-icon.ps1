# Sinh Resources/AppIcon.png (1024) và AppIcon.ico (16..256) cho bản Windows.
# Gradient #616FFA → #29C2B3, bong bóng phụ đề trắng (giống Scripts/make-icon.swift của bản macOS).
param([string]$OutDir = (Join-Path $PSScriptRoot "..\ScreenTranslator\Resources"))
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

function New-IconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = [double]$size
    $inset = $s * 0.06; $w = $s - 2 * $inset; $r = $w * 0.22
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($inset, $inset, 2 * $r, 2 * $r, 180, 90)
    $path.AddArc($inset + $w - 2 * $r, $inset, 2 * $r, 2 * $r, 270, 90)
    $path.AddArc($inset + $w - 2 * $r, $inset + $w - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $path.AddArc($inset, $inset + $w - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $path.CloseFigure()
    $c1 = [System.Drawing.Color]::FromArgb(255, 0x61, 0x6F, 0xFA)
    $c2 = [System.Drawing.Color]::FromArgb(255, 0x29, 0xC2, 0xB3)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.PointF]::new(0, 0)), ([System.Drawing.PointF]::new($s, $s)), $c1, $c2
    $g.FillPath($brush, $path)

    # Bong bóng
    $bx = $s * 0.20; $by = $s * 0.24; $bw = $s * 0.60; $bh = $s * 0.42; $br = $bh * 0.28
    $bubble = New-Object System.Drawing.Drawing2D.GraphicsPath
    $bubble.AddArc($bx, $by, 2 * $br, 2 * $br, 180, 90)
    $bubble.AddArc($bx + $bw - 2 * $br, $by, 2 * $br, 2 * $br, 270, 90)
    $bubble.AddArc($bx + $bw - 2 * $br, $by + $bh - 2 * $br, 2 * $br, 2 * $br, 0, 90)
    $bubble.AddArc($bx, $by + $bh - 2 * $br, 2 * $br, 2 * $br, 90, 90)
    $bubble.CloseFigure()
    $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $g.FillPath($white, $bubble)
    $tail = @(
        [System.Drawing.PointF]::new($bx + $bw * 0.22, $by + $bh - 1),
        [System.Drawing.PointF]::new($bx + $bw * 0.18, $by + $bh + $s * 0.13),
        [System.Drawing.PointF]::new($bx + $bw * 0.42, $by + $bh - 1))
    $g.FillPolygon($white, $tail)
    # Hai dòng "phụ đề"
    $lineBrush = New-Object System.Drawing.SolidBrush $c1
    $lh = $s * 0.055
    $g.FillRectangle($lineBrush, [single]($bx + $bw * 0.16), [single]($by + $bh * 0.30), [single]($bw * 0.68), [single]$lh)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush $c2), [single]($bx + $bw * 0.16), [single]($by + $bh * 0.58), [single]($bw * 0.46), [single]$lh)
    $g.Dispose()
    return $bmp
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$big = New-IconBitmap 1024
$big.Save((Join-Path $OutDir "AppIcon.png"), [System.Drawing.Imaging.ImageFormat]::Png)

# ICO nhiều cỡ (PNG nhúng)
$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = @()
foreach ($sz in $sizes) {
    $b = New-IconBitmap $sz
    $ms = New-Object System.IO.MemoryStream
    $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs += , $ms.ToArray()
}
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $out
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $sz = $sizes[$i]; $d = $pngs[$i]
    $bw.Write([byte]($(if ($sz -ge 256) { 0 } else { $sz })))
    $bw.Write([byte]($(if ($sz -ge 256) { 0 } else { $sz })))
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$d.Length); $bw.Write([UInt32]$offset)
    $offset += $d.Length
}
foreach ($d in $pngs) { $bw.Write($d) }
$bw.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $OutDir "AppIcon.ico"), $out.ToArray())
Write-Host "Đã tạo AppIcon.png và AppIcon.ico trong $OutDir"
