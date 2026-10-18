param(
  [Parameter(Mandatory = $true)][string]$Scene,
  [Parameter(Mandatory = $true)][string]$Users,
  [Parameter(Mandatory = $true)][string]$Alive,
  [Parameter(Mandatory = $true)][string]$Window,
  [Parameter(Mandatory = $true)][string]$Commands,
  [Parameter(Mandatory = $true)][string]$ClearSignal,
  [string]$Labels = '',
  [string]$Log = ''
)

# Whale's Pencil -- the desktop half: tray icon plus one transparent window.
#
# The window is the board. It paints two independent sets of marks:
#   - the agent's scene, written by the Host into -Scene;
#   - the user's own strokes, kept here and mirrored to -Users so the agent can
#     see what the user drew.
#
# Two command channels run in opposite directions, both as files:
#   Host -> window   -Commands  {"rev":N,"erase":{"ids":[],"rects":[]}}
#   window -> Host   -ClearSignal  touched whenever the user clears the board
#
# Tray menu is deliberately minimal: take the pencil, clear everything, leave
# draw mode, quit. There is no separate eraser entry: the eraser lives on the
# right mouse button inside draw mode.
#
# This file must stay ASCII-only: Windows PowerShell 5.1 reads a .ps1 without a
# BOM in the ANSI code page, and non-ASCII text would corrupt the script.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public struct WpRect { public int Left; public int Top; public int Right; public int Bottom; }

public static class WpNative
{
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out WpRect rect);
    [DllImport("user32.dll")] public static extern IntPtr SetCursor(IntPtr hCursor);
    [DllImport("user32.dll")] public static extern IntPtr LoadCursor(IntPtr hInstance, IntPtr name);

    public static readonly IntPtr IDC_ARROW = new IntPtr(32512);
    public static readonly IntPtr IDC_CROSS = new IntPtr(32515);

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;
}
'@

$POLL_MS = 120
$ALIVE_STALE_MS = 6000
$MIN_WIDTH = 1
$MAX_WIDTH = 30
$USER_COLOR = '#FF2020'

$script:trace = $Log
function Note([string]$m) {
  if ([string]::IsNullOrEmpty($script:trace)) { return }
  try { Add-Content -LiteralPath $script:trace -Value ("{0:HH:mm:ss.fff} {1}" -f (Get-Date), $m) } catch { }
}

# Localised text arrives as JSON, not as arguments: a command line is the wrong
# channel for non-ASCII on Windows, and this file must stay ASCII-readable.
# These English defaults cover a missing or unreadable label file.
$script:tr = @{
  pencil = 'Take the pencil'
  call = 'Summon the agent'
  clear = 'Clear everything'
  exitDraw = 'Stop drawing'
  quit = 'Quit'
  trayTitle = "User's Pencil"
  widthSuffix = 'px'
}
if (-not [string]::IsNullOrEmpty($Labels) -and (Test-Path -LiteralPath $Labels)) {
  try {
    $pairs = ([System.IO.File]::ReadAllText($Labels)) | ConvertFrom-Json
    foreach ($prop in $pairs.PSObject.Properties) { $script:tr[$prop.Name] = [string]$prop.Value }
  } catch { }
}

# --- state ------------------------------------------------------------------
$script:scale = 1.0
$script:mode = 'idle'           # idle | ink | erase
$script:width = 4
$script:eraserRadius = 16
$script:strokes = New-Object System.Collections.ArrayList
# Text the user typed on the board. Kept apart from strokes because it is placed
# and erased differently, but both travel in user.json so the agent can read it.
$script:texts = New-Object System.Collections.ArrayList
$script:editor = $null
$script:hidden = New-Object System.Collections.ArrayList
$script:activePoints = $null    # ArrayList of double[2] while a stroke is drawn
$script:activeErase = $false
$script:lastSceneWrite = [datetime]::MinValue
$script:lastCommandRev = -1
$script:lastClearTick = -1
$script:userRev = 0
$script:strokeSeq = 0
$script:badgeTimer = $null
$script:pendingMode = $null
# The tray hands its intent to the dispatcher through a file, not a variable:
# the event handler and the timer do not reliably share PowerShell scope, and a
# lost assignment is exactly a pencil that cannot be picked up.
$script:trayFile = Join-Path (Split-Path -Parent $Window) 'tray.txt'
function Post-Intent([string]$intent) {
  try { [System.IO.File]::WriteAllText($script:trayFile, $intent) } catch { }
  Note ("tray: intent " + $intent)
}
function Take-Intent {
  try {
    if (-not (Test-Path -LiteralPath $script:trayFile)) { return $null }
    $text = ([System.IO.File]::ReadAllText($script:trayFile)).Trim()
    Remove-Item -LiteralPath $script:trayFile -Force -ErrorAction SilentlyContinue
    return $text
  } catch { return $null }
}


# --- window -----------------------------------------------------------------
$grid = New-Object System.Windows.Controls.Grid

$sceneCanvas = New-Object System.Windows.Controls.Canvas
$sceneCanvas.Background = [System.Windows.Media.Brushes]::Transparent
[void]$grid.Children.Add($sceneCanvas)

$inkCanvas = New-Object System.Windows.Controls.Canvas
$inkCanvas.Background = [System.Windows.Media.Brushes]::Transparent
[void]$grid.Children.Add($inkCanvas)

$win = New-Object System.Windows.Window
$win.WindowStyle = 'None'
$win.AllowsTransparency = $true
# A 5% wash so the layer is visible: with a fully transparent window there is no
# way to tell "the board is capturing the pointer" from "nothing happened".
# TINT_ALPHA is the only knob -- 0 restores an invisible board.
$TINT_ALPHA = 0.05
$tintByte = [byte][Math]::Round(255 * $TINT_ALPHA)
$win.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb($tintByte, 0, 0, 0))
$win.ShowInTaskbar = $false
$win.Topmost = $true
$win.ShowActivated = $false
$win.ResizeMode = [System.Windows.ResizeMode]::NoResize
$win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
$win.Left = [System.Windows.SystemParameters]::VirtualScreenLeft
$win.Top = [System.Windows.SystemParameters]::VirtualScreenTop
$win.Width = [System.Windows.SystemParameters]::VirtualScreenWidth
$win.Height = [System.Windows.SystemParameters]::VirtualScreenHeight
$win.Content = $grid
$win.Focusable = $true

# Size badge: shows the current stroke width while the wheel turns.
$badge = New-Object System.Windows.Controls.Border
$badge.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(230, 20, 20, 24))
$badge.CornerRadius = New-Object System.Windows.CornerRadius(10)
$badge.Padding = New-Object System.Windows.Thickness(12, 6, 12, 6)
$badge.Visibility = 'Collapsed'
$badge.IsHitTestVisible = $false
$badgeText = New-Object System.Windows.Controls.TextBlock
$badgeText.Foreground = [System.Windows.Media.Brushes]::White
$badgeText.FontSize = 14
$badgeText.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
$badge.Child = $badgeText
[void]$sceneCanvas.Children.Add($badge)

function Update-Styles {
  $handle = New-Object System.Windows.Interop.WindowInteropHelper($win)
  $style = [WpNative]::GetWindowLong($handle.Handle, [WpNative]::GWL_EXSTYLE)
  $base = $style -bor [WpNative]::WS_EX_LAYERED -bor [WpNative]::WS_EX_TOOLWINDOW
  if ($script:mode -eq 'idle') {
    $base = $base -bor [WpNative]::WS_EX_TRANSPARENT -bor [WpNative]::WS_EX_NOACTIVATE
  } else {
    $base = $base -band (-bnot [WpNative]::WS_EX_TRANSPARENT) -band (-bnot [WpNative]::WS_EX_NOACTIVATE)
  }
  [void][WpNative]::SetWindowLong($handle.Handle, [WpNative]::GWL_EXSTYLE, $base)
  [void][WpNative]::SetWindowPos($handle.Handle, [WpNative]::HWND_TOPMOST, 0, 0, 0, 0,
    [WpNative]::SWP_NOSIZE -bor [WpNative]::SWP_NOMOVE -bor [WpNative]::SWP_NOACTIVATE -bor [WpNative]::SWP_SHOWWINDOW)
}

function Set-Cursor {
  # A layered, transparent window frequently ignores `Window.Cursor`: WPF only
  # hands the cursor to the element under the pointer, and a fully transparent
  # host can lose that round trip. `Mouse.OverrideCursor` is applied by the input
  # manager itself, so it survives the transparency; the element cursors stay as
  # a fallback for hosts where the override is ignored.
  $shape = if ($script:mode -eq 'erase') {
    [System.Windows.Input.Cursors]::Cross
  } elseif ($script:mode -eq 'ink') {
    [System.Windows.Input.Cursors]::Pen
  } else {
    [System.Windows.Input.Cursors]::Arrow
  }
  try {
    [System.Windows.Input.Mouse]::OverrideCursor = if ($script:mode -eq 'idle') { $null } else { $shape }
  } catch { }
  try { $win.Cursor = $shape } catch { }
  try { $grid.Cursor = $shape } catch { }
  try { $sceneCanvas.Cursor = $shape } catch { }
  try { $inkCanvas.Cursor = $shape } catch { }
  Note ("cursor -> " + $script:mode)
}

# --- painting the agent scene -----------------------------------------------
function Brush([string]$hex) {
  if ([string]::IsNullOrWhiteSpace($hex)) { return $null }
  try {
    if ($hex -match '^rgba?\(([^)]+)\)$') {
      $p = $Matches[1].Split(',')
      $r = [byte][double]$p[0].Trim(); $g = [byte][double]$p[1].Trim(); $b = [byte][double]$p[2].Trim()
      $a = if ($p.Length -ge 4) { [double]$p[3].Trim() } else { 1.0 }
      if ($a -le 1.0) { $a = $a * 255 }
      return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb([byte]$a, $r, $g, $b))
    }
    $c = [System.Windows.Media.ColorConverter]::new().ConvertFromString($hex)
    return New-Object System.Windows.Media.SolidColorBrush($c)
  } catch { return $null }
}

function Map-X([double]$v, [bool]$screen) { if ($screen) { return $v / $script:scale } else { return $v * $win.Width / 100.0 } }
function Map-Y([double]$v, [bool]$screen) { if ($screen) { return $v / $script:scale } else { return $v * $win.Height / 100.0 } }

function Add-Item($item, [bool]$screen) {
  $type = [string]$item.type
  switch ($type) {
    'rect' {
      $w = Map-X ([double]$item.w) $screen; $h = Map-Y ([double]$item.h) $screen
      if ($w -le 0 -or $h -le 0) { return }
      $s = New-Object System.Windows.Shapes.Rectangle
      $s.Width = $w; $s.Height = $h
      $s.RadiusX = if ($item.radius) { [double]$item.radius } else { 8 }
      $s.RadiusY = $s.RadiusX
      $f = Brush ([string]$item.fill); if ($f -ne $null) { $s.Fill = $f }
      $st = Brush ([string]$item.stroke)
      if ($st -ne $null) { $s.Stroke = $st; $s.StrokeThickness = if ($item.width) { [double]$item.width } else { 3 } }
      [System.Windows.Controls.Canvas]::SetLeft($s, (Map-X ([double]$item.x) $screen))
      [System.Windows.Controls.Canvas]::SetTop($s, (Map-Y ([double]$item.y) $screen))
      [void]$sceneCanvas.Children.Add($s)
    }
    'ellipse' {
      $w = Map-X ([double]$item.w) $screen; $h = Map-Y ([double]$item.h) $screen
      if ($w -le 0 -or $h -le 0) { return }
      $s = New-Object System.Windows.Shapes.Ellipse
      $s.Width = $w; $s.Height = $h
      $f = Brush ([string]$item.fill); if ($f -ne $null) { $s.Fill = $f }
      $st = Brush ([string]$item.stroke)
      if ($st -ne $null) { $s.Stroke = $st; $s.StrokeThickness = if ($item.width) { [double]$item.width } else { 3 } }
      [System.Windows.Controls.Canvas]::SetLeft($s, (Map-X ([double]$item.x) $screen))
      [System.Windows.Controls.Canvas]::SetTop($s, (Map-Y ([double]$item.y) $screen))
      [void]$sceneCanvas.Children.Add($s)
    }
    'path' {
      $pts = $item.points
      if ($pts -eq $null -or $pts.Count -lt 2) { return }
      $poly = New-Object System.Windows.Shapes.Polyline
      for ($i = 0; $i -lt $pts.Count; $i++) {
        [void]$poly.Points.Add((New-Object System.Windows.Point((Map-X ([double]$pts[$i][0]) $screen), (Map-Y ([double]$pts[$i][1]) $screen))))
      }
      $st = Brush ([string]$item.stroke); if ($st -ne $null) { $poly.Stroke = $st }
      $poly.StrokeThickness = if ($item.width) { [double]$item.width } else { 4 }
      $poly.StrokeLineJoin = 'Round'; $poly.StrokeStartLineCap = 'Round'; $poly.StrokeEndLineCap = 'Round'
      [void]$sceneCanvas.Children.Add($poly)
    }
    'arrow' {
      $x1 = Map-X ([double]$item.x1) $screen; $y1 = Map-Y ([double]$item.y1) $screen
      $x2 = Map-X ([double]$item.x2) $screen; $y2 = Map-Y ([double]$item.y2) $screen
      $st = Brush ([string]$item.stroke)
      $th = if ($item.width) { [double]$item.width } else { 4 }
      $line = New-Object System.Windows.Shapes.Line
      $line.X1 = $x1; $line.Y1 = $y1; $line.X2 = $x2; $line.Y2 = $y2
      if ($st -ne $null) { $line.Stroke = $st }
      $line.StrokeThickness = $th; $line.StrokeStartLineCap = 'Round'; $line.StrokeEndLineCap = 'Round'
      [void]$sceneCanvas.Children.Add($line)
      $ang = [Math]::Atan2($y2 - $y1, $x2 - $x1)
      $head = if ($item.head) { [double]$item.head } else { 18 }
      foreach ($sp in @(0.45, -0.45)) {
        $w = New-Object System.Windows.Shapes.Line
        $w.X1 = $x2; $w.Y1 = $y2
        $w.X2 = $x2 - $head * [Math]::Cos($ang + $sp); $w.Y2 = $y2 - $head * [Math]::Sin($ang + $sp)
        if ($st -ne $null) { $w.Stroke = $st }
        $w.StrokeThickness = $th; $w.StrokeStartLineCap = 'Round'; $w.StrokeEndLineCap = 'Round'
        [void]$sceneCanvas.Children.Add($w)
      }
    }
    'text' {
      $text = [string]$item.text
      if ([string]::IsNullOrEmpty($text)) { return }
      $tb = New-Object System.Windows.Controls.TextBlock
      $tb.Text = $text
      $size = if ($item.size) { [double]$item.size } else { 18 }
      $tb.FontSize = $size
      $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI, Segoe UI')
      $tb.FontWeight = if ([string]$item.weight -eq 'bold') { [System.Windows.FontWeights]::SemiBold } else { [System.Windows.FontWeights]::Normal }
      $tb.MaxWidth = 1200
      $tb.TextWrapping = 'Wrap'
      $ink = Brush ([string]$item.color); if ($ink -ne $null) { $tb.Foreground = $ink }
      $tb.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
        Color = [System.Windows.Media.Colors]::Black; BlurRadius = 6; ShadowDepth = 0; Opacity = 0.65
      }
      $align = [string]$item.align
      $left = Map-X ([double]$item.x) $screen
      if ($align -eq 'center' -or $align -eq 'right') {
        $tb.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        if ($align -eq 'center') { $left = $left - $tb.DesiredSize.Width / 2 } else { $left = $left - $tb.DesiredSize.Width }
      }
      [System.Windows.Controls.Canvas]::SetLeft($tb, $left)
      [System.Windows.Controls.Canvas]::SetTop($tb, (Map-Y ([double]$item.y) $screen))
      [void]$sceneCanvas.Children.Add($tb)
    }
    'image' {
      $src = [string]$item.src
      $comma = $src.IndexOf(',')
      if ($comma -lt 0) { return }
      try {
        $bytes = [Convert]::FromBase64String($src.Substring($comma + 1))
        $ms = New-Object System.IO.MemoryStream (, $bytes)
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.StreamSource = $ms; $bmp.EndInit(); $bmp.Freeze()
        $img = New-Object System.Windows.Controls.Image
        $img.Source = $bmp
        $img.Width = Map-X ([double]$item.w) $screen
        $img.Height = Map-Y ([double]$item.h) $screen
        if ($item.alpha -ne $null) { $img.Opacity = [double]$item.alpha }
        [System.Windows.Controls.Canvas]::SetLeft($img, (Map-X ([double]$item.x) $screen))
        [System.Windows.Controls.Canvas]::SetTop($img, (Map-Y ([double]$item.y) $screen))
        [void]$sceneCanvas.Children.Add($img)
      } catch { }
    }
    'pixels' {
      $w = [int]$item.w; $h = [int]$item.h
      if ($w -le 0 -or $h -le 0) { return }
      try {
        $bytes = [Convert]::FromBase64String([string]$item.data)
        $wb = New-Object System.Windows.Media.Imaging.WriteableBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Bgra32, $null)
        $dst = New-Object byte[] ($w * $h * 4)
        for ($i = 0; $i -lt ($w * $h); $i++) {
          $s = $i * 4
          if ($s + 3 -lt $bytes.Length) {
            $dst[$s] = $bytes[$s + 2]; $dst[$s + 1] = $bytes[$s + 1]
            $dst[$s + 2] = $bytes[$s]; $dst[$s + 3] = $bytes[$s + 3]
          }
        }
        $wb.WritePixels((New-Object System.Windows.Int32Rect 0, 0, $w, $h), $dst, $w * 4, 0)
        $wb.Freeze()
        $img = New-Object System.Windows.Controls.Image
        $img.Source = $wb
        $img.Width = Map-X ([double]$w) $screen
        $img.Height = Map-Y ([double]$h) $screen
        $img.Stretch = 'Fill'
        [System.Windows.Controls.Canvas]::SetLeft($img, (Map-X ([double]$item.x) $screen))
        [System.Windows.Controls.Canvas]::SetTop($img, (Map-Y ([double]$item.y) $screen))
        [void]$sceneCanvas.Children.Add($img)
      } catch { }
    }
  }
}

function Render-Scene([string]$json) {
  # Rebuild only the agent layer; the badge and the ink layer are siblings.
  $keep = @($badge)
  $sceneCanvas.Children.Clear()
  foreach ($k in $keep) { [void]$sceneCanvas.Children.Add($k) }

  if ([string]::IsNullOrWhiteSpace($json)) { return }
  $doc = $null
  try { $doc = $json | ConvertFrom-Json } catch { return }
  if ($doc -eq $null) { return }
  if ($doc.enabled -ne $true) { return }

  $screen = ([string]$doc.unit -ne 'window')
  foreach ($item in @($doc.layers)) {
    if ($item -eq $null) { continue }
    $id = [string]$item.id
    if ($id -ne '' -and $script:hidden -contains $id) { continue }
    Add-Item $item $screen
  }
}

# --- the user's ink ---------------------------------------------------------
function Render-Ink {
  $inkCanvas.Children.Clear()
  foreach ($stroke in $script:strokes) {
    $poly = New-Object System.Windows.Shapes.Polyline
    foreach ($pt in $stroke.points) {
      [void]$poly.Points.Add((New-Object System.Windows.Point(([double]$pt[0] / $script:scale), ([double]$pt[1] / $script:scale))))
    }
    $poly.Stroke = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(255, 32, 32))
    $poly.StrokeThickness = [Math]::Max(1.0, ([double]$stroke.width / $script:scale))
    $poly.StrokeLineJoin = 'Round'; $poly.StrokeStartLineCap = 'Round'; $poly.StrokeEndLineCap = 'Round'
    [void]$inkCanvas.Children.Add($poly)
  }
  foreach ($label in $script:texts) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = [string]$label.text
    $tb.FontSize = [double]$label.size
    $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI, Segoe UI')
    $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(255, 48, 48))
    $tb.MaxWidth = 900
    $tb.TextWrapping = 'Wrap'
    $tb.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
      Color = [System.Windows.Media.Colors]::Black; BlurRadius = 5; ShadowDepth = 0; Opacity = 0.6
    }
    [System.Windows.Controls.Canvas]::SetLeft($tb, ([double]$label.x / $script:scale))
    [System.Windows.Controls.Canvas]::SetTop($tb, ([double]$label.y / $script:scale))
    [void]$inkCanvas.Children.Add($tb)
  }
}

function Save-User {
  try {
    $payload = [ordered]@{
      revision = [int]$script:userRev
      strokes = @($script:strokes | ForEach-Object {
        [ordered]@{ id = $_.id; width = $_.width; color = $USER_COLOR; points = @($_.points) }
      })
      texts = @($script:texts | ForEach-Object {
        [ordered]@{ id = $_.id; x = $_.x; y = $_.y; size = $_.size; text = $_.text }
      })
      hidden = @($script:hidden)
    }
    $json = $payload | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::WriteAllText($Users, $json)
  } catch { Note ("save-user failed: " + $_.Exception.Message) }
}

# Whether a point falls inside one user text's box.
function Hit-Text([double]$x, [double]$y, [double]$r) {
  for ($i = $script:texts.Count - 1; $i -ge 0; $i--) {
    $t = $script:texts[$i]
    $w = [Math]::Max(80, ([string]$t.text).Length * [double]$t.size * 0.72)
    $h = [double]$t.size * 1.6
    if ($x -ge $t.x - $r -and $x -le $t.x + $w + $r -and $y -ge $t.y - $r -and $y -le $t.y + $h + $r) { return $i }
  }
  return -1
}

function Hit-Stroke([double]$x, [double]$y, [double]$r) {
  for ($i = $script:strokes.Count - 1; $i -ge 0; $i--) {
    $s = $script:strokes[$i]
    foreach ($pt in $s.points) {
      $dx = [double]$pt[0] - $x; $dy = [double]$pt[1] - $y
      if (($dx * $dx + $dy * $dy) -le ($r * $r)) { return $i }
    }
  }
  return -1
}

function Hit-Scene([double]$x, [double]$y, [double]$r) {
  # Best effort: the scene is a vector list the Host owns, so erasing one of its
  # marks is expressed as "hide this id". A mark's bounding box is recovered
  # from what the Host published.
  #
  # Walk from the last mark to the first, and skip what is already hidden. Later
  # marks are painted on top, so they are what the pointer is really aiming at;
  # without this, a large rectangle hides every mark drawn inside it, and the
  # second erase attempt keeps hitting the already-hidden rectangle instead.
  $boxes = @($script:sceneBoxes)
  for ($i = $boxes.Count - 1; $i -ge 0; $i--) {
    $entry = $boxes[$i]
    if ($entry -eq $null) { continue }
    if ($script:hidden -contains $entry.id) { continue }
    if ($x -ge $entry.x - $r -and $x -le $entry.x + $entry.w + $r -and $y -ge $entry.y - $r -and $y -le $entry.y + $entry.h + $r) {
      return $entry.id
    }
  }
  return $null
}

$script:sceneBoxes = @()

function Capture-Boxes([string]$json) {
  $boxes = @()
  if ([string]::IsNullOrWhiteSpace($json)) { $script:sceneBoxes = $boxes; return }
  $doc = $null
  try { $doc = $json | ConvertFrom-Json } catch { $script:sceneBoxes = $boxes; return }
  if ($doc -eq $null) { $script:sceneBoxes = $boxes; return }
  foreach ($item in @($doc.layers)) {
    if ($item -eq $null) { continue }
    $id = [string]$item.id
    if ($id -eq '') { continue }
    $type = [string]$item.type
    $x = 0.0; $y = 0.0; $w = 0.0; $h = 0.0
    switch ($type) {
      'rect'   { $x = [double]$item.x; $y = [double]$item.y; $w = [double]$item.w; $h = [double]$item.h }
      'ellipse'{ $x = [double]$item.x; $y = [double]$item.y; $w = [double]$item.w; $h = [double]$item.h }
      'text'   { $x = [double]$item.x; $y = [double]$item.y; $w = 260; $h = 60 }
      'image'  { $x = [double]$item.x; $y = [double]$item.y; $w = [double]$item.w; $h = [double]$item.h }
      'pixels' { $x = [double]$item.x; $y = [double]$item.y; $w = [double]$item.w; $h = [double]$item.h }
      'arrow'  {
        $x = [Math]::Min([double]$item.x1, [double]$item.x2); $y = [Math]::Min([double]$item.y1, [double]$item.y2)
        $w = [Math]::Abs([double]$item.x2 - [double]$item.x1); $h = [Math]::Abs([double]$item.y2 - [double]$item.y1)
      }
      'path' {
        $px = @($item.points)
        if ($px.Count -gt 0) {
          $xs = @(); $ys = @()
          foreach ($p in $px) { $xs += [double]$p[0]; $ys += [double]$p[1] }
          $x = ($xs | Measure-Object -Minimum).Minimum; $y = ($ys | Measure-Object -Minimum).Minimum
          $w = ($xs | Measure-Object -Maximum).Maximum - $x; $h = ($ys | Measure-Object -Maximum).Maximum - $y
        }
      }
    }
    $boxes += [pscustomobject]@{ id = $id; x = $x; y = $y; w = $w; h = $h }
  }
  $script:sceneBoxes = $boxes
}

# --- draw mode --------------------------------------------------------------
function Enter-DrawMode {
  if ($script:mode -ne 'idle') { return }
  $script:mode = 'ink'
  $script:activePoints = $null
  $script:activeErase = $false
  Update-Styles
  Set-Cursor
  try { $win.Activate() } catch { }
  try { [void]$win.Focus() } catch { }
  try { [void][System.Windows.Input.Keyboard]::Focus($win) } catch { }
  Note 'draw mode on'
}

function Exit-DrawMode {
  if ($script:mode -eq 'idle') { return }
  $script:mode = 'idle'
  $script:activePoints = $null
  $script:activeErase = $false
  Update-Styles
  Set-Cursor
  Note 'draw mode off'
}

function Show-Badge([double]$x, [double]$y) {
  $badgeText.Text = ("{0} {1}" -f $script:width, $script:tr.widthSuffix)
  [System.Windows.Controls.Canvas]::SetLeft($badge, $x / $script:scale + 18)
  [System.Windows.Controls.Canvas]::SetTop($badge, $y / $script:scale + 18)
  $badge.Visibility = 'Visible'
  if ($script:badgeTimer -ne $null) { $script:badgeTimer.Stop() }
  $script:badgeTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:badgeTimer.Interval = [TimeSpan]::FromMilliseconds(900)
  $script:badgeTimer.Add_Tick({ $badge.Visibility = 'Collapsed'; $script:badgeTimer.Stop() })
  $script:badgeTimer.Start()
}

# --- host command channel ---------------------------------------------------
function Apply-Commands {
  if (-not (Test-Path -LiteralPath $Commands)) { return }
  $raw = $null
  try { $raw = [System.IO.File]::ReadAllText($Commands) } catch { return }
  if ([string]::IsNullOrWhiteSpace($raw)) { return }
  $cmd = $null
  try { $cmd = $raw | ConvertFrom-Json } catch { return }
  if ($cmd -eq $null) { return }
  $rev = if ($cmd.rev -ne $null) { [int]$cmd.rev } else { 0 }
  if ($rev -le $script:lastCommandRev) { return }
  $script:lastCommandRev = $rev

  # A mode switch may ride the same channel, so the Host can arm the pencil.
  if ($cmd.mode -ne $null) {
    $mode = [string]$cmd.mode
    if ($mode -eq 'ink') { Enter-DrawMode }
    elseif ($mode -eq 'idle') { Exit-DrawMode }
  }

  $erase = $cmd.erase
  if ($erase -eq $null) { return }

  $ids = @()
  if ($erase.ids -ne $null) { $ids = @($erase.ids | ForEach-Object { [string]$_ }) }
  foreach ($id in $ids) {
    if ($id -ne '' -and -not ($script:hidden -contains $id)) { [void]$script:hidden.Add($id) }
  }

  $rects = @()
  if ($erase.rects -ne $null) { $rects = @($erase.rects) }
  foreach ($r in $rects) {
    $x = [double]$r.x; $y = [double]$r.y; $w = [double]$r.w; $h = [double]$r.h
    # Hide scene marks whose box overlaps the erase rect.
    foreach ($box in @($script:sceneBoxes)) {
      if ($box -eq $null) { continue }
      $overlap = -not ($box.x + $box.w -lt $x -or $box.x -gt $x + $w -or $box.y + $box.h -lt $y -or $box.y -gt $y + $h)
      if ($overlap -and -not ($script:hidden -contains $box.id)) { [void]$script:hidden.Add($box.id) }
    }
    # Remove user strokes inside the rect.
    for ($i = $script:strokes.Count - 1; $i -ge 0; $i--) {
      $s = $script:strokes[$i]
      $remove = $false
      foreach ($pt in $s.points) {
        if ([double]$pt[0] -ge $x -and [double]$pt[0] -le $x + $w -and [double]$pt[1] -ge $y -and [double]$pt[1] -le $y + $h) { $remove = $true; break }
      }
      if ($remove) { $script:strokes.RemoveAt($i) }
    }
  }

  $script:userRev++
  Render-Ink
  Save-User
  Note ("commands applied rev " + $rev)
}

# --- the user's text box ----------------------------------------------------
#
# Shift+right-click drops an editor where the pointer is; type, Enter to keep it,
# Esc to drop it. The text survives as a red label on the board and travels to
# the agent in user.json, so "what the user means" can be written, not only drawn.
function Open-Editor([double]$x, [double]$y) {
  Close-Editor
  $border = New-Object System.Windows.Controls.Border
  $border.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(235, 24, 24, 28))
  $border.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(255, 48, 48))
  $border.BorderThickness = New-Object System.Windows.Thickness(1)
  $border.CornerRadius = New-Object System.Windows.CornerRadius(6)
  $border.Padding = New-Object System.Windows.Thickness(6, 2, 6, 2)

  $box = New-Object System.Windows.Controls.TextBox
  $box.Background = [System.Windows.Media.Brushes]::Transparent
  $box.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(255, 220, 220))
  $box.CaretBrush = [System.Windows.Media.Brushes]::White
  $box.BorderThickness = New-Object System.Windows.Thickness(0)
  $box.FontSize = 18
  $box.MinWidth = 180
  $box.MaxWidth = 760
  $box.AcceptsReturn = $false
  $box.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI, Segoe UI')
  $border.Child = $box

  [System.Windows.Controls.Canvas]::SetLeft($border, ($x / $script:scale))
  [System.Windows.Controls.Canvas]::SetTop($border, ($y / $script:scale))
  [void]$inkCanvas.Children.Add($border)
  $script:editor = [pscustomobject]@{ border = $border; box = $box; x = $x; y = $y }

  $box.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
      $e.Handled = $true
      Commit-Editor
    } elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
      $e.Handled = $true
      Close-Editor
    }
  })
  try { [void]$box.Focus() } catch { }
  try { [void][System.Windows.Input.Keyboard]::Focus($box) } catch { }
  Note 'editor opened'
}

function Commit-Editor {
  if ($script:editor -eq $null) { return }
  $text = [string]$script:editor.box.Text
  $x = $script:editor.x
  $y = $script:editor.y
  Close-Editor
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  $script:strokeSeq++
  [void]$script:texts.Add([pscustomobject]@{
    id = ("t{0}-{1}" -f $script:strokeSeq, [DateTime]::UtcNow.Ticks)
    x = $x; y = $y; size = 18; text = $text.Trim()
  })
  $script:userRev++
  Render-Ink
  Save-User
  Note ("text committed: " + $text)
}

function Close-Editor {
  if ($script:editor -eq $null) { return }
  try { [void]$inkCanvas.Children.Remove($script:editor.border) } catch { }
  $script:editor = $null
}

# --- summon the agent -------------------------------------------------------
#
# The user cannot talk to the agent on demand, so the tray lends them a door. The
# window only says "now": it drops a request marker and the Host captures,
# attaches, and delivers, so no screenshot file is ever written here.
function Summon-Agent {
  $base = Split-Path -Parent $Window
  $payload = [ordered]@{ at = [DateTime]::UtcNow.Ticks; note = 'user pressed summon on the tray' }
  try {
    [System.IO.File]::WriteAllText((Join-Path $base 'summon.json'), ($payload | ConvertTo-Json -Compress))
  } catch {
    Note ("summon failed: " + $_.Exception.Message)
    return
  }
  Note 'summoned: request posted'
}

# --- clear (user) -----------------------------------------------------------
function Clear-All {
  $script:strokes.Clear()
  $script:texts.Clear()
  $script:hidden.Clear()
  $script:sceneBoxes = @()
  $script:userRev++
  Render-Ink
  $sceneCanvas.Children.Clear()
  [void]$sceneCanvas.Children.Add($badge)
  Save-User
  try { [System.IO.File]::WriteAllText($ClearSignal, [string][DateTime]::UtcNow.Ticks) } catch { }
  Note 'cleared by user'
}

# --- tray -------------------------------------------------------------------
function New-TrayIcon {
  try {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 255, 32, 32)), 3.2
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawLine($pen, 3, 13, 13, 3)
    $tip = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 255, 220, 220)), 1.4
    $g.DrawLine($tip, 10.5, 2.5, 13.5, 5.5)
    $g.Dispose(); $pen.Dispose(); $tip.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
  } catch {
    return [System.Drawing.SystemIcons]::Application
  }
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = New-TrayIcon
$notify.Text = $script:tr.trayTitle
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemPencil = New-Object System.Windows.Forms.ToolStripMenuItem($script:tr.pencil)
$itemCall = New-Object System.Windows.Forms.ToolStripMenuItem($script:tr.call)
$itemClear = New-Object System.Windows.Forms.ToolStripMenuItem($script:tr.clear)
$itemExitDraw = New-Object System.Windows.Forms.ToolStripMenuItem($script:tr.exitDraw)
$itemQuit = New-Object System.Windows.Forms.ToolStripMenuItem($script:tr.quit)

$itemPencil.add_Click({ Post-Intent 'ink' })
$itemCall.add_Click({ Post-Intent 'call' })
$itemClear.add_Click({ Post-Intent 'clear' })
$itemExitDraw.add_Click({ Post-Intent 'idle' })
$itemQuit.add_Click({ Post-Intent 'quit' })
[void]$menu.Items.Add($itemPencil)
[void]$menu.Items.Add($itemCall)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($itemClear)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($itemExitDraw)
[void]$menu.Items.Add($itemQuit)
$notify.ContextMenuStrip = $menu
$notify.add_MouseClick({
  param($s, $e)
  Note ("tray: mouse click button=" + $e.Button)
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Post-Intent 'ink' }
})
$notify.add_MouseDown({
  param($s, $e)
  Note ("tray: mouse down button=" + $e.Button)
})
$menu.add_Opening({ Note 'tray: menu opening' })
Note 'tray: icon created'

# --- window events ----------------------------------------------------------
$win.Add_MouseLeftButtonDown({
  if ($script:mode -eq 'idle') { return }
  $p = $_.GetPosition($win)
  $x = $p.X * $script:scale; $y = $p.Y * $script:scale
  if ($script:mode -eq 'erase') {
    $script:activeErase = $true
    $hit = Hit-Stroke $x $y ([double]$script:eraserRadius)
    if ($hit -ge 0) { $script:strokes.RemoveAt($hit); $script:userRev++; Render-Ink; Save-User }
    $id = Hit-Scene $x $y ([double]$script:eraserRadius)
    if ($id -ne $null -and -not ($script:hidden -contains $id)) {
      [void]$script:hidden.Add($id); $script:userRev++
      $raw = $null; try { $raw = [System.IO.File]::ReadAllText($Scene) } catch { }
      Render-Scene $raw; Save-User
    }
    return
  }
  $script:activePoints = New-Object System.Collections.ArrayList
  [void]$script:activePoints.Add(@($x, $y))
})

$win.Add_MouseMove({
  if ($script:mode -eq 'idle') { return }
  # Belt and braces: WPF resets the cursor on every WM_SETCURSOR, which a
  # transparent host window can skip. Painting it here keeps the shape steady
  # under the pointer while the user draws.
  try {
    [void][WpNative]::SetCursor([WpNative]::LoadCursor([IntPtr]::Zero, [WpNative]::IDC_CROSS))
  } catch { }
  $p = $_.GetPosition($win)
  $x = $p.X * $script:scale; $y = $p.Y * $script:scale

  if ($script:activeErase) {
    $hit = Hit-Stroke $x $y ([double]$script:eraserRadius)
    if ($hit -ge 0) { $script:strokes.RemoveAt($hit); $script:userRev++; Render-Ink; Save-User }
    $t = Hit-Text $x $y ([double]$script:eraserRadius)
    if ($t -ge 0) { $script:texts.RemoveAt($t); $script:userRev++; Render-Ink; Save-User }
    $id = Hit-Scene $x $y ([double]$script:eraserRadius)
    if ($id -ne $null -and -not ($script:hidden -contains $id)) {
      [void]$script:hidden.Add($id); $script:userRev++
      $raw = $null; try { $raw = [System.IO.File]::ReadAllText($Scene) } catch { }
      Render-Scene $raw; Save-User
    }
    return
  }

  if ($script:activePoints -eq $null) { return }
  $last = $script:activePoints[$script:activePoints.Count - 1]
  $dx = $x - [double]$last[0]; $dy = $y - [double]$last[1]
  if (($dx * $dx + $dy * $dy) -lt 9) { return }
  [void]$script:activePoints.Add(@($x, $y))

  # Live preview: extend the last polyline without a full repaint.
  if ($inkCanvas.Children.Count -eq 0) { return }
  $poly = $inkCanvas.Children[$inkCanvas.Children.Count - 1]
  if ($poly -is [System.Windows.Shapes.Polyline]) {
    [void]$poly.Points.Add((New-Object System.Windows.Point($p.X, $p.Y)))
  }
})

$win.Add_MouseLeftButtonUp({
  if ($script:activeErase) { $script:activeErase = $false; return }
  if ($script:activePoints -eq $null) { return }
  $pts = $script:activePoints
  $script:activePoints = $null
  if ($pts.Count -lt 2) { return }
  $script:strokeSeq++
  $stroke = [pscustomobject]@{
    id = ("u{0}-{1}" -f $script:strokeSeq, [DateTime]::UtcNow.Ticks)
    width = [int]$script:width
    points = @($pts)
  }
  [void]$script:strokes.Add($stroke)
  $script:userRev++
  Render-Ink
  Save-User
})

$win.Add_MouseRightButtonDown({
  if ($script:mode -eq 'idle') { return }
  $p = $_.GetPosition($win)
  $x = $p.X * $script:scale; $y = $p.Y * $script:scale
  # Shift+right-click is the text tool: place an editor instead of erasing.
  if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0) {
    $script:activeErase = $false
    Open-Editor $x $y
    return
  }
  $script:activeErase = $true
  $hit = Hit-Stroke $x $y ([double]$script:eraserRadius)
  if ($hit -ge 0) { $script:strokes.RemoveAt($hit); $script:userRev++; Render-Ink; Save-User }
  $t = Hit-Text $x $y ([double]$script:eraserRadius)
  if ($t -ge 0) { $script:texts.RemoveAt($t); $script:userRev++; Render-Ink; Save-User }
})

$win.Add_MouseRightButtonUp({ $script:activeErase = $false })

$win.Add_MouseWheel({
  if ($script:mode -eq 'idle') { return }
  $step = if ($_.Delta -gt 0) { 1 } else { -1 }
  $script:width = [Math]::Max($MIN_WIDTH, [Math]::Min($MAX_WIDTH, $script:width + $step))
  $p = $_.GetPosition($win)
  Show-Badge ($p.X * $script:scale) ($p.Y * $script:scale)
})

$win.Add_KeyDown({
  if ($_.Key -eq [System.Windows.Input.Key]::Escape) { Exit-DrawMode }
})

$win.Add_Closed({
  try { $notify.Visible = $false; $notify.Dispose() } catch { }
  try { Remove-Item -LiteralPath $Window -Force -ErrorAction SilentlyContinue } catch { }
})

# --- timers -----------------------------------------------------------------
$ticker = New-Object System.Windows.Threading.DispatcherTimer
$ticker.Interval = [TimeSpan]::FromMilliseconds($POLL_MS)
$ticker.Add_Tick({
  try {
    # Tray intents run here, on the dispatcher: this is the only thread that may
    # touch the window's styles or its cursor.
    $want = Take-Intent
    if ($want -ne $null) {
      Note ("apply intent: " + $want)
      switch ($want) {
        'ink'   { Enter-DrawMode }
        'idle'  { Exit-DrawMode }
        'clear' { Clear-All }
        'call'  { Summon-Agent }
        'quit'  { $win.Close(); return }
      }
    }

    if (-not (Test-Path -LiteralPath $Alive)) { Note 'heartbeat gone'; $win.Close(); return }
    try {
      $age = ([DateTime]::Now - (Get-Item -LiteralPath $Alive).LastWriteTime).TotalMilliseconds
      if ($age -gt $ALIVE_STALE_MS) { Note 'heartbeat stale'; $win.Close(); return }
    } catch { $win.Close(); return }

    if (Test-Path -LiteralPath $Scene) {
      try {
        $w = (Get-Item -LiteralPath $Scene).LastWriteTime
        if ($w -ne $script:lastSceneWrite) {
          $script:lastSceneWrite = $w
          $raw = [System.IO.File]::ReadAllText($Scene)
          Capture-Boxes $raw
          Render-Scene $raw
          Note 'scene rendered'
        }
      } catch { }
    }

    Apply-Commands
  } catch { Note ("tick: " + $_.Exception.Message) }
})

$win.Add_Loaded({
  try {
    $h = New-Object System.Windows.Interop.WindowInteropHelper($win)
    $r = New-Object WpRect
    if ([WpNative]::GetClientRect($h.Handle, [ref]$r)) {
      $phys = $r.Right - $r.Left
      if ($phys -gt 0 -and $win.ActualWidth -gt 0) { $script:scale = $phys / $win.ActualWidth }
    }
  } catch { }
  if ($script:scale -le 0) { $script:scale = 1.0 }

  try { [System.IO.File]::WriteAllText($Window, [string]$PID) } catch { }
  Update-Styles
  Set-Cursor
  if (Test-Path -LiteralPath $Scene) {
    try {
      $raw = [System.IO.File]::ReadAllText($Scene)
      Capture-Boxes $raw
      Render-Scene $raw
    } catch { }
  }
  $ticker.Start()
  Note ("loaded scale=" + $script:scale)
})

[void]$win.ShowDialog()
try { $notify.Visible = $false; $notify.Dispose() } catch { }
try { Remove-Item -LiteralPath $Window -Force -ErrorAction SilentlyContinue } catch { }
exit 0
