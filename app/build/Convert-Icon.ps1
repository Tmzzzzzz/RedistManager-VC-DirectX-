# Convert-Icon.ps1
# Convert logo.jpeg into a multi-size Windows icon (app.ico, PNG-encoded,
# sizes 16/24/32/48/64/128/256). Re-run after replacing logo.jpeg.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\Convert-Icon.ps1

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

Add-Type -AssemblyName System.Drawing

$assetsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
$srcPath = Join-Path $assetsDir 'logo.jpeg'
$icoPath = Join-Path $assetsDir 'app.ico'

$sizes = 16, 24, 32, 48, 64, 128, 256

# 1) Load source image; fit into a square canvas (aspect-preserving, transparent padding).
$src = [System.Drawing.Bitmap]::FromFile($srcPath)
$baseSize = [Math]::Max($src.Width, $src.Height)
$base = New-Object System.Drawing.Bitmap($baseSize, $baseSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($base)
$g.Clear([System.Drawing.Color]::Transparent)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
$x = [int](($baseSize - $src.Width) / 2)
$y = [int](($baseSize - $src.Height) / 2)
$g.DrawImage($src, $x, $y, $src.Width, $src.Height)
$g.Dispose()
$src.Dispose()

# 2) Render each target size to PNG bytes.
$pngs = @{}
foreach ($size in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g2 = [System.Drawing.Graphics]::FromImage($bmp)
    $g2.Clear([System.Drawing.Color]::Transparent)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g2.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g2.DrawImage($base, 0, 0, $size, $size)
    $g2.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs[$size] = $ms.ToArray()
    $ms.Dispose()
    $bmp.Dispose()
}
$base.Dispose()

# 3) Assemble ICO: ICONDIR + ICONDIRENTRY[] + PNG payloads.
$count = $sizes.Count
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)

# ICONDIR
$bw.Write([UInt16]0)      # reserved
$bw.Write([UInt16]1)      # type = icon
$bw.Write([UInt16]$count) # count

$offset = 6 + 16 * $count
foreach ($size in $sizes) {
    $data = $pngs[$size]
    # ICONDIRENTRY (width/height use 0 to mean 256)
    $dim = if ($size -ge 256) { 0 } else { $size }
    $bw.Write([Byte]$dim)      # width
    $bw.Write([Byte]$dim)      # height
    $bw.Write([Byte]0)         # colorCount
    $bw.Write([Byte]0)         # reserved
    $bw.Write([UInt16]1)       # planes
    $bw.Write([UInt16]32)      # bitCount
    $bw.Write([UInt32]$data.Length) # bytesInRes
    $bw.Write([UInt32]$offset)      # imageOffset
    $offset += $data.Length
}
foreach ($size in $sizes) {
    $bw.Write($pngs[$size])
}
$bw.Flush()
[System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
$bw.Dispose()
$ms.Dispose()

Write-Host ("Built: {0} ({1:N0} bytes)" -f $icoPath, (Get-Item -LiteralPath $icoPath).Length)
