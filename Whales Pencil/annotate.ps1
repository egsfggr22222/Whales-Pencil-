param(
  [Parameter(Mandatory = $true)][string]$Spec
)

# Composite pencil marks onto an image and write a new PNG.
#
# `pencil annotate` needs to draw on a picture rather than on the screen, and it
# must not depend on an image library in Node. System.Drawing is part of
# Windows, so this script is the whole renderer: it reads one JSON spec from a
# file or stdin, paints the marks, and writes the result beside the source.
#
# Spec: {"source":"C:\\in.png","output":"C:\\out.png","unit":"screen|window",
#        "items":[ ...same primitives as the board... ]}
#
# For an image, "screen" means picture pixels: the annotator draws at the same
# coordinates the board would use, so a mark composed for the screen lands on
# the same place in the picture when the picture was a screenshot of it.
#
# This file must stay ASCII-only.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$raw = if ($Spec -eq '-') { [Console]::In.ReadToEnd() } else { [System.IO.File]::ReadAllText($Spec) }
if ([string]::IsNullOrWhiteSpace($raw)) { Write-Error 'annotate: empty spec'; exit 2 }
$doc = $raw | ConvertFrom-Json
if ($doc -eq $null) { Write-Error 'annotate: unreadable spec'; exit 2 }

$source = [string]$doc.source
if (-not (Test-Path -LiteralPath $source)) { Write-Error ("annotate: no such file: " + $source); exit 2 }

$output = [string]$doc.output
if ([string]::IsNullOrWhiteSpace($output)) {
  $dir = [System.IO.Path]::GetDirectoryName($source)
  $name = [System.IO.Path]::GetFileNameWithoutExtension($source)
  $output = [System.IO.Path]::Combine($dir, ($name + '-pencil.png'))
}

$src = [System.Drawing.Image]::FromFile($source)
$bmp = New-Object System.Drawing.Bitmap $src.Width, $src.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.DrawImage($src, 0, 0, $src.Width, $src.Height)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

$screenUnit = ([string]$doc.unit -ne 'window')
$scaleX = $src.Width / 100.0
$scaleY = $src.Height / 100.0

function SX([double]$v) { if ($screenUnit) { return $v } else { return $v * $scaleX } }
function SY([double]$v) { if ($screenUnit) { return $v } else { return $v * $scaleY } }

function Make-Color([string]$text, [int]$alpha) {
  if ([string]::IsNullOrWhiteSpace($text)) { return [System.Drawing.Color]::Transparent }
  try {
    if ($text -match '^rgba?\(([^)]+)\)$') {
      $p = $Matches[1].Split(',')
      $r = [int][double]$p[0].Trim(); $gg = [int][double]$p[1].Trim(); $b = [int][double]$p[2].Trim()
      $a = if ($p.Length -ge 4) { [int]([double]$p[3].Trim() * 255) } else { $alpha }
      return [System.Drawing.Color]::FromArgb($a, $r, $gg, $b)
    }
    $c = [System.Drawing.ColorTranslator]::FromHtml($text)
    if ($alpha -lt 255) { return [System.Drawing.Color]::FromArgb($alpha, $c.R, $c.G, $c.B) }
    return $c
  } catch { return [System.Drawing.Color]::Transparent }
}

function Make-Pen([string]$text, [double]$width) {
  $c = Make-Color $text 255
  if ($c -eq [System.Drawing.Color]::Transparent) { $c = [System.Drawing.Color]::Cyan }
  $p = New-Object System.Drawing.Pen $c, ([Math]::Max(1.0, $width))
  $p.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $p.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $p.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  return $p
}

foreach ($item in @($doc.items)) {
  if ($item -eq $null) { continue }
  $type = [string]$item.type
  switch ($type) {
    'rect' {
      $x = SX ([double]$item.x); $y = SY ([double]$item.y)
      $w = SX ([double]$item.w); $h = SY ([double]$item.h)
      if ($w -le 0 -or $h -le 0) { continue }
      $fill = [string]$item.fill
      if (-not [string]::IsNullOrWhiteSpace($fill) -and $fill -ne 'none') {
        $fb = New-Object System.Drawing.SolidBrush (Make-Color $fill 64)
        $g.FillRectangle($fb, $x, $y, $w, $h)
        $fb.Dispose()
      }
      $stroke = [string]$item.stroke
      if (-not [string]::IsNullOrWhiteSpace($stroke) -and $stroke -ne 'none') {
        $pen = Make-Pen $stroke ([double]$item.width)
        $g.DrawRectangle($pen, $x, $y, $w, $h)
        $pen.Dispose()
      }
    }
    'ellipse' {
      $x = SX ([double]$item.x); $y = SY ([double]$item.y)
      $w = SX ([double]$item.w); $h = SY ([double]$item.h)
      if ($w -le 0 -or $h -le 0) { continue }
      $fill = [string]$item.fill
      if (-not [string]::IsNullOrWhiteSpace($fill) -and $fill -ne 'none') {
        $fb = New-Object System.Drawing.SolidBrush (Make-Color $fill 64)
        $g.FillEllipse($fb, $x, $y, $w, $h)
        $fb.Dispose()
      }
      $stroke = [string]$item.stroke
      if (-not [string]::IsNullOrWhiteSpace($stroke) -and $stroke -ne 'none') {
        $pen = Make-Pen $stroke ([double]$item.width)
        $g.DrawEllipse($pen, $x, $y, $w, $h)
        $pen.Dispose()
      }
    }
    'path' {
      $pts = @($item.points)
      if ($pts.Count -lt 2) { continue }
      $pen = Make-Pen ([string]$item.stroke) ([double]$item.width)
      $buffer = New-Object System.Collections.Generic.List[System.Drawing.PointF]
      foreach ($p in $pts) { $buffer.Add((New-Object System.Drawing.PointF((SX ([double]$p[0])), (SY ([double]$p[1]))))) }
      $g.DrawLines($pen, $buffer.ToArray())
      $pen.Dispose()
    }
    'arrow' {
      $x1 = SX ([double]$item.x1); $y1 = SY ([double]$item.y1)
      $x2 = SX ([double]$item.x2); $y2 = SY ([double]$item.y2)
      $pen = Make-Pen ([string]$item.stroke) ([double]$item.width)
      $g.DrawLine($pen, $x1, $y1, $x2, $y2)
      $head = if ($item.head) { [double]$item.head } else { 18 }
      $ang = [Math]::Atan2($y2 - $y1, $x2 - $x1)
      foreach ($sp in @(0.45, -0.45)) {
        $g.DrawLine($pen, $x2, $y2, ($x2 - $head * [Math]::Cos($ang + $sp)), ($y2 - $head * [Math]::Sin($ang + $sp)))
      }
      $pen.Dispose()
    }
    'text' {
      $text = [string]$item.text
      if ([string]::IsNullOrEmpty($text)) { continue }
      $size = if ($item.size) { [double]$item.size } else { 18 }
      $style = if ([string]$item.weight -eq 'bold') { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
      $font = New-Object System.Drawing.Font 'Microsoft YaHei UI', $size, $style
      $brush = New-Object System.Drawing.SolidBrush (Make-Color ([string]$item.color) 255)
      $x = SX ([double]$item.x); $y = SY ([double]$item.y)
      $align = [string]$item.align
      $fmt = New-Object System.Drawing.StringFormat
      if ($align -eq 'center') { $fmt.Alignment = [System.Drawing.StringAlignment]::Center }
      elseif ($align -eq 'right') { $fmt.Alignment = [System.Drawing.StringAlignment]::Far }
      else { $fmt.Alignment = [System.Drawing.StringAlignment]::Near }
      $g.DrawString($text, $font, $brush, [single]$x, [single]$y, $fmt)
      $fmt.Dispose(); $brush.Dispose(); $font.Dispose()
    }
    'image' {
      $src2 = [string]$item.src
      $comma = $src2.IndexOf(',')
      if ($comma -lt 0) { continue }
      try {
        $bytes = [Convert]::FromBase64String($src2.Substring($comma + 1))
        $ms = New-Object System.IO.MemoryStream (, $bytes)
        $sub = [System.Drawing.Image]::FromStream($ms)
        $w = if ($item.w) { SX ([double]$item.w) } else { $sub.Width }
        $h = if ($item.h) { SY ([double]$item.h) } else { $sub.Height }
        $g.DrawImage($sub, (SX ([double]$item.x)), (SY ([double]$item.y)), $w, $h)
        $sub.Dispose(); $ms.Dispose()
      } catch { }
    }
  }
}

$g.Dispose()
$outDir = [System.IO.Path]::GetDirectoryName($output)
if (-not [string]::IsNullOrEmpty($outDir) -and -not (Test-Path -LiteralPath $outDir)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$bmp.Save($output, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
$src.Dispose()

Write-Output $output
exit 0
