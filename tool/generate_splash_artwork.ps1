$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = (Get-Location).Path
$logoPath = Join-Path $root 'assets/icons/appicon.png'
$basePath = Join-Path $root 'assets/splash/launch_artwork.png'
$designWidth = 360
$designHeight = 800
$highScale = 4
$canvasWidth = $designWidth * $highScale
$canvasHeight = $designHeight * $highScale
$canvas = [System.Drawing.Bitmap]::new(
    $canvasWidth,
    $canvasHeight,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
)
$graphics = [System.Drawing.Graphics]::FromImage($canvas)
$graphics.Clear([System.Drawing.Color]::Transparent)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

$logo = [System.Drawing.Image]::FromFile($logoPath)
$logoSize = 150 * $highScale
$logoRect = [System.Drawing.Rectangle]::new(
    ($canvasWidth - $logoSize) / 2,
    213 * $highScale,
    $logoSize,
    $logoSize
)
$graphics.DrawImage($logo, $logoRect)

$center = [System.Drawing.StringFormat]::new()
$center.Alignment = [System.Drawing.StringAlignment]::Center
$center.LineAlignment = [System.Drawing.StringAlignment]::Near
$textColor = [System.Drawing.SolidBrush]::new(
    [System.Drawing.Color]::FromArgb(255, 241, 245, 249)
)
$creditColor = [System.Drawing.SolidBrush]::new(
    [System.Drawing.Color]::FromArgb(255, 156, 163, 175)
)
$mottoFont = [System.Drawing.Font]::new(
    'Segoe UI',
    16 * $highScale,
    [System.Drawing.FontStyle]::Bold,
    [System.Drawing.GraphicsUnit]::Pixel
)
$creditFont = [System.Drawing.Font]::new(
    'Segoe UI',
    13 * $highScale,
    [System.Drawing.FontStyle]::Regular,
    [System.Drawing.GraphicsUnit]::Pixel
)
$motto = "Bridging the Digital Divide.`nEmpowering Every Mind."
$mottoRect = [System.Drawing.RectangleF]::new(
    8 * $highScale,
    393 * $highScale,
    344 * $highScale,
    56 * $highScale
)
$creditRect = [System.Drawing.RectangleF]::new(
    8 * $highScale,
    478 * $highScale,
    344 * $highScale,
    24 * $highScale
)
$graphics.DrawString($motto, $mottoFont, $textColor, $mottoRect, $center)
$graphics.DrawString(
    'Developed by Maxwell Dumbu @MTC',
    $creditFont,
    $creditColor,
    $creditRect,
    $center
)

function Save-ScaledArtwork([double]$factor, [string]$path) {
    $directory = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $output = [System.Drawing.Bitmap]::new(
        $designWidth * $factor,
        $designHeight * $factor,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $renderer = [System.Drawing.Graphics]::FromImage($output)
    $renderer.Clear([System.Drawing.Color]::Transparent)
    $renderer.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $renderer.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $renderer.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $renderer.DrawImage($canvas, 0, 0, $output.Width, $output.Height)
    $output.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $renderer.Dispose()
    $output.Dispose()
}

$assetTargets = @(
    @{ Factor = 1; Path = $basePath },
    @{ Factor = 1.5; Path = (Join-Path $root 'assets/splash/1.5x/launch_artwork.png') },
    @{ Factor = 2; Path = (Join-Path $root 'assets/splash/2.0x/launch_artwork.png') },
    @{ Factor = 3; Path = (Join-Path $root 'assets/splash/3.0x/launch_artwork.png') },
    @{ Factor = 4; Path = (Join-Path $root 'assets/splash/4.0x/launch_artwork.png') }
)
foreach ($target in $assetTargets) {
    Save-ScaledArtwork $target.Factor $target.Path
}

$androidTargets = @(
    @{ Factor = 1; Density = 'mdpi' },
    @{ Factor = 1.5; Density = 'hdpi' },
    @{ Factor = 2; Density = 'xhdpi' },
    @{ Factor = 3; Density = 'xxhdpi' },
    @{ Factor = 4; Density = 'xxxhdpi' }
)
foreach ($target in $androidTargets) {
    $path = Join-Path $root "android/app/src/main/res/drawable-$($target.Density)/maxai_launch_artwork.png"
    Save-ScaledArtwork $target.Factor $path
}

$creditFont.Dispose()
$mottoFont.Dispose()
$creditColor.Dispose()
$textColor.Dispose()
$center.Dispose()
$logo.Dispose()
$graphics.Dispose()
$canvas.Dispose()
