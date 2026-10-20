param(
  [Parameter(Mandatory = $true)][string]$Scene,
  [Parameter(Mandatory = $true)][string]$Users,
  [Parameter(Mandatory = $true)][string]$Alive,
  [Parameter(Mandatory = $true)][string]$Window,
  [Parameter(Mandatory = $true)][string]$Commands,
  [Parameter(Mandatory = $true)][string]$ClearSignal,
  [string]$Status = '',
  [string]$StopSignal = '',
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

    // The global toggle. A registered hotkey reaches this process no matter which
    // window has focus, which is the point: the board must be reachable without
    // hunting for a tray icon first.
    [DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    // Moving the borderless ball window. DragMove() needs a caption or resize
    // frame to grab, and this window has neither, so the shell's own move command
    // is used instead: WM_SYSCOMMAND with SC_MOVE moves any top-level window.
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();

    public const uint WM_SYSCOMMAND = 0x0112;
    public const int SC_MOVE = 0xF010;

    public const uint MOD_ALT = 0x0001;
    public const uint MOD_CONTROL = 0x0002;
    public const uint MOD_SHIFT = 0x0004;
    public const uint MOD_WIN = 0x0008;
    public const uint VK_L = 0x4C;

    public static readonly IntPtr IDC_ARROW = new IntPtr(32512);
    public static readonly IntPtr IDC_CROSS = new IntPtr(32515);
    // The text caret, shown while the pointer rests over text.
    public static readonly IntPtr IDC_IBEAM = new IntPtr(32513);

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
  islandThinking = 'Thinking'
  islandTool = 'Calling'
  islandRead = 'Reading'
  islandStop = 'Stop the agent'
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
# Where the board menu was opened, in physical pixels. "Text box" places its
# editor here, so typing starts where the user right-clicked.
$script:menuAtX = $null
$script:menuAtY = $null
# The agent's text boxes, kept so a press can be routed to the one under the
# pointer and Hit-Text can include them.
$script:sceneTexts = New-Object System.Collections.ArrayList
# The text box a drag is currently selecting inside, and where the press landed
# in its text. The board drives the selection because it owns the mouse.
$script:activeText = $null
$script:selectBase = 0
$script:lastSceneWrite = [datetime]::MinValue
$script:lastCommandRev = -1
$script:lastClearTick = -1
$script:userRev = 0
$script:strokeSeq = 0
$script:badgeTimer = $null
$script:pendingMode = $null
# A registered hotkey reports through the window message hook, which runs on the
# WPF thread; the mode switch itself waits for the dispatcher tick like every
# other intent.
$script:pendingToggle = $false
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

# --- the island -------------------------------------------------------------
#
# Reads the status the Host publishes and turns it into the pill. Nothing here
# invents state: when the file says idle, the island hides.

# Ask the Host to stop every running turn.
#
# The click is the whole authority: the Host cancels the sessions and clears the
# status, so the island disappears on its own next tick. Nothing here guesses at
# success.
#
# A file, not HTTP. The browser carrier admits only requests carrying a live
# session, and this process has none, so a POST would come back 401. Writing a
# tick is the same channel the clear signal already uses in this direction.
function Request-Stop {
  if ($script:islandStopPending) { return }
  $script:islandStopPending = $true
  try { $islandStop.IsEnabled = $false } catch { }
  Note 'island: stop requested'

  try {
    $tick = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    [System.IO.File]::WriteAllText($StopSignal, [string]$tick)
    Note ("island: stop tick " + $tick)
  } catch {
    Note ("island: stop failed: " + $_.Exception.Message)
  } finally {
    $script:islandStopPending = $false
    try { $islandStop.IsEnabled = $true } catch { }
  }
}

# Track whether the pointer is over the pill.
#
# Unused since the island became its own window: that window is always hit-testable,
# so WPF sees the pointer itself. Kept as a no-op so the ticker stays unchanged.
function Update-IslandHover { }

function Update-Island {
  if (-not (Test-Path -LiteralPath $Status)) {
    if ($script:islandVisible) { Hide-Island }
    return
  }

  $stamp = [datetime]::MinValue
  try { $stamp = (Get-Item -LiteralPath $Status).LastWriteTime } catch { return }

  # Re-read only when the file changed: the tick is fast, the file is not.
  if ($stamp -ne $script:islandLastWrite) {
    $script:islandLastWrite = $stamp
    $doc = $null
    try { $doc = [System.IO.File]::ReadAllText($Status) | ConvertFrom-Json } catch { return }
    if ($doc -eq $null) { return }

    $busy = $doc.busy -eq $true
    if (-not $busy) {
      if ($script:islandVisible) { Hide-Island }
      return
    }

    $phase = [string]$doc.phase
    $tool = [string]$doc.tool
    $script:islandPhase = $phase
    $script:islandTool = $tool
    $script:islandSince = 0
    if ($null -ne $doc.since -and [double]$doc.since -gt 0) { $script:islandSince = [double]$doc.since }

    if (-not $script:islandVisible) { Show-Island }

    # Three distinct readings, because they mean different things to someone
    # watching: thinking (nothing to report yet), reading (looking at something),
    # calling (changing or producing something). The colours match: quiet grey,
    # cyan for read, green for action.
    if ($phase -eq 'read' -and $tool -ne '') {
      $islandText.Text = ("{0} {1}" -f $script:tr.islandRead, $tool)
      $islandDot.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0, 229, 255))
    } elseif ($phase -eq 'tool' -and $tool -ne '') {
      $islandText.Text = ("{0} {1}" -f $script:tr.islandTool, $tool)
      $islandDot.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(124, 255, 178))
    } else {
      $islandText.Text = $script:tr.islandThinking
      $islandDot.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(120, 132, 148))
    }
    Note ("island text: " + $phase + " / " + $tool)
  }

  # Elapsed time, and the breathing dot. Both are cheap and run every tick so the
  # island looks alive instead of frozen between events.
  if ($script:islandVisible) {
    if ($script:islandSince -gt 0) {
      # "since" is Unix milliseconds (what JavaScript Date.now() returns), not
      # .NET ticks: measuring it against UtcNow.Ticks yields a number so large it
      # overflows Int32 and throws on every tick, which is what froze the timer.
      $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      $elapsedMs = $nowMs - [long]$script:islandSince
      if ($elapsedMs -ge 0) {
        # Plain concatenation rather than -f: a format string like "{0}m{1:d2}s"
        # makes PowerShell parse "m" and "s" as invalid format specifiers.
        $total = [int][Math]::Floor($elapsedMs / 1000.0)
        $mins = [int][Math]::Floor($total / 60)
        $secs = $total % 60
        if ($mins -ge 1) {
          $islandElapsed.Text = ([string]$mins) + "m" + ($secs.ToString("00")) + "s"
        } else {
          $islandElapsed.Text = ([string]$secs) + "s"
        }
      }
    }
    $phaseTick = ([DateTime]::UtcNow.Ticks / 100000.0) % 20
    $opacity = 0.35 + 0.65 * ([Math]::Abs($phaseTick - 10) / 10.0)
    $islandDot.Opacity = [Math]::Round($opacity, 2)
  }
}

#
# The island is a SEPARATE window, not part of the board.
#
# It used to live here, on the board's own full-screen overlay. That cannot work:
# the board is click-through whenever the user is not drawing, and a click-through
# window swallows no clicks at all, so the stop button was visible but unreachable.
# Turning click-through off while hovering was not enough either, because the
# board's idle mode overrides it on the next style update. A small always-listening
# window of its own is the only shape that both sits above everything and receives
# the click.
#
# It is shown only while something is running. A status readout that never goes
# away stops being information and becomes clutter.
$islandWindow = $null
$islandStop = $null
$islandText = $null
$islandElapsed = $null
$islandDot = $null

$script:islandVisible = $false
$script:islandPhase = ''
$script:islandSince = 0
# Guards against a second press while one stop request is in flight.
$script:islandStopPending = $false
$script:islandTool = ''
$script:islandLastWrite = [datetime]::MinValue

# Build the island's own window.
#
# Separate from the board on purpose: the board is click-through whenever the user
# is not drawing, and a click-through window receives no clicks at all. This one is
# small, always hit-testable and always topmost, created once and shown or hidden
# as work starts and stops.
function Initialize-IslandWindow {
  $script:islandWindow = New-Object System.Windows.Window
  $script:islandWindow.WindowStyle = 'None'
  $script:islandWindow.AllowsTransparency = $true
  $script:islandWindow.Background = [System.Windows.Media.Brushes]::Transparent
  $script:islandWindow.ShowInTaskbar = $false
  $script:islandWindow.Topmost = $true
  $script:islandWindow.ShowActivated = $false
  $script:islandWindow.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $script:islandWindow.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
  $script:islandWindow.SizeToContent = 'WidthAndHeight'

  $pill = New-Object System.Windows.Controls.Border
  $pill.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(224, 18, 18, 22))
  $pill.CornerRadius = New-Object System.Windows.CornerRadius(18)
  $pill.Padding = New-Object System.Windows.Thickness(16, 8, 10, 8)

  $panel = New-Object System.Windows.Controls.StackPanel
  $panel.Orientation = 'Horizontal'
  $panel.VerticalAlignment = 'Center'

  # A dot that breathes while work is happening: the text says what, the motion
  # says that it is still going.
  $script:islandDot = New-Object System.Windows.Shapes.Ellipse
  $script:islandDot.Width = 9
  $script:islandDot.Height = 9
  $script:islandDot.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0, 229, 255))
  $script:islandDot.VerticalAlignment = 'Center'
  $script:islandDot.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)

  $script:islandText = New-Object System.Windows.Controls.TextBlock
  $script:islandText.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(236, 240, 245))
  $script:islandText.FontSize = 13
  $script:islandText.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI, Segoe UI')
  $script:islandText.VerticalAlignment = 'Center'
  $script:islandText.TextTrimming = 'CharacterEllipsis'
  $script:islandText.MaxWidth = 720

  $script:islandElapsed = New-Object System.Windows.Controls.TextBlock
  $script:islandElapsed.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(150, 160, 172))
  $script:islandElapsed.FontSize = 12
  $script:islandElapsed.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
  $script:islandElapsed.VerticalAlignment = 'Center'
  $script:islandElapsed.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
  $script:islandElapsed.MinWidth = 38

  # The stop button: a filled red square with nothing inside, so no white glyph
  # shows through the middle. Transparent button chrome, one solid child.
  $script:islandStop = New-Object System.Windows.Controls.Button
  $script:islandStop.Width = 32
  $script:islandStop.Height = 32
  $script:islandStop.Padding = New-Object System.Windows.Thickness(0)
  $script:islandStop.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
  $script:islandStop.VerticalAlignment = 'Center'
  $script:islandStop.Cursor = [System.Windows.Input.Cursors]::Hand
  $script:islandStop.ToolTip = $script:tr.islandStop
  $script:islandStop.Background = [System.Windows.Media.Brushes]::Transparent
  $script:islandStop.BorderThickness = New-Object System.Windows.Thickness(0)
  $script:islandStop.Focusable = $false

  $islandFill = New-Object System.Windows.Controls.Border
  $islandFill.Width = 18
  $islandFill.Height = 18
  $islandFill.CornerRadius = New-Object System.Windows.CornerRadius(5)
  $islandFill.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(226, 70, 78))
  $script:islandStop.Content = $islandFill
  $script:islandStop.Add_Click({ Request-Stop })

  [void]$panel.Children.Add($script:islandDot)
  [void]$panel.Children.Add($script:islandText)
  [void]$panel.Children.Add($script:islandElapsed)
  [void]$panel.Children.Add($script:islandStop)
  $pill.Child = $panel
  $script:islandWindow.Content = $pill

  # A tool window that never activates: it is a readout, not an app. It still takes
  # clicks, which is the whole reason it exists as its own window.
  $script:islandWindow.Add_SourceInitialized({
    try {
      $h = New-Object System.Windows.Interop.WindowInteropHelper($script:islandWindow)
      $style = [WpNative]::GetWindowLong($h.Handle, [WpNative]::GWL_EXSTYLE)
      $style = $style -bor [WpNative]::WS_EX_TOOLWINDOW -bor [WpNative]::WS_EX_NOACTIVATE
      [void][WpNative]::SetWindowLong($h.Handle, [WpNative]::GWL_EXSTYLE, $style)
    } catch { }
  })
  $script:islandWindow.Show()
  $script:islandWindow.Hide()
}

# Put the island on screen, centred on the primary monitor's top edge.
function Show-Island {
  if ($script:islandWindow -eq $null) {
    try { Initialize-IslandWindow } catch { Note ("island init failed: " + $_.Exception.Message); return }
  }
  try {
    $script:islandWindow.Show()
    # Centring needs the measured width, which only exists after layout.
    $script:islandWindow.UpdateLayout()
    $screen = [System.Windows.SystemParameters]::PrimaryScreenWidth
    $screenLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
    $w = $script:islandWindow.ActualWidth
    if ($w -le 0) { $w = $script:islandWindow.DesiredSize.Width }
    $script:islandWindow.Left = [Math]::Round($screenLeft + ($screen - $w) / 2.0)
    $script:islandWindow.Top = 10
    $h = New-Object System.Windows.Interop.WindowInteropHelper($script:islandWindow)
    [void][WpNative]::SetWindowPos($h.Handle, [WpNative]::HWND_TOPMOST, 0, 0, 0, 0,
      [WpNative]::SWP_NOSIZE -bor [WpNative]::SWP_NOMOVE -bor [WpNative]::SWP_NOACTIVATE)
    $script:islandVisible = $true
    Note ("island shown at " + $script:islandWindow.Left + "," + $script:islandWindow.Top)
  } catch { Note ("island show failed: " + $_.Exception.Message) }
}

# Take the island off screen.
function Hide-Island {
  if ($script:islandWindow -ne $null) {
    try { $script:islandWindow.Hide() } catch { }
  }
  $script:islandVisible = $false
  Note 'island hidden'
}

function Update-Styles {
  $handle = New-Object System.Windows.Interop.WindowInteropHelper($win)
  $style = [WpNative]::GetWindowLong($handle.Handle, [WpNative]::GWL_EXSTYLE)
  $base = $style -bor [WpNative]::WS_EX_LAYERED -bor [WpNative]::WS_EX_TOOLWINDOW
  # The board itself stays click-through whenever it is not being drawn on. The
  # island no longer needs this branch: it is its own window and always listens.
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
  # A layered, transparent window frequently ignores Window.Cursor: WPF only
  # hands the cursor to the element under the pointer, and a fully transparent
  # host can lose that round trip. Mouse.OverrideCursor is applied by the input
  # manager itself, so it survives the transparency; the element cursors stay as
  # a fallback for hosts where the override is ignored.
  #
  # Drawing uses the crosshair everywhere, never the pencil. Every mouse move also
  # repaints the cursor with SetCursor, and having two different shapes fight over
  # it made the pointer flicker between a pencil and a cross for as long as the
  # board was open. One shape, set everywhere, cannot flicker.
  $shape = if ($script:mode -eq 'idle') {
    [System.Windows.Input.Cursors]::Arrow
  } else {
    [System.Windows.Input.Cursors]::Cross
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
      # A read-only TextBox, like the user's own labels: agent text is a container
      # too, so it can be selected by character and copied with Ctrl+C without the
      # user having to retype anything.
      $tb = New-Object System.Windows.Controls.TextBox
      $tb.Text = $text
      $tb.IsReadOnly = $true
      $tb.IsReadOnlyCaretVisible = $true
      $tb.AcceptsReturn = $true
      $tb.BorderThickness = New-Object System.Windows.Thickness(0)
      $tb.Background = [System.Windows.Media.Brushes]::Transparent
      $tb.Padding = New-Object System.Windows.Thickness(0)
      $tb.SelectionBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(120, 90, 160, 255))
      $tb.SelectionOpacity = 0.55
      $tb.IsHitTestVisible = $true
      $tb.Tag = 'scenetext'
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
      Add-TextCopyHandlers $tb
      $align = [string]$item.align
      $left = Map-X ([double]$item.x) $screen
      if ($align -eq 'center' -or $align -eq 'right') {
        $tb.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        if ($align -eq 'center') { $left = $left - $tb.DesiredSize.Width / 2 } else { $left = $left - $tb.DesiredSize.Width }
      }
      [System.Windows.Controls.Canvas]::SetLeft($tb, $left)
      [System.Windows.Controls.Canvas]::SetTop($tb, (Map-Y ([double]$item.y) $screen))
      [void]$sceneCanvas.Children.Add($tb)
      # Remembered so a press can be routed to this box and so Hit-Text sees it.
      [void]$script:sceneTexts.Add([pscustomobject]@{ item = $item; box = $tb })
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
  # The boxes just went with the children; the index is rebuilt as they are made.
  $script:sceneTexts = New-Object System.Collections.ArrayList

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
    # A read-only TextBox, not a TextBlock.
    #
    # Everything the user asked of text selection comes for free from the control
    # that already implements it: drag to select by character, double-click a word,
    # Ctrl+A, and Ctrl+C to copy. Re-implementing that by painting a highlight over
    # a TextBlock produced exactly the wrong behaviour - the whole block lit up and
    # nothing could be copied.
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Text = [string]$label.text
    $tb.IsReadOnly = $true
    $tb.IsReadOnlyCaretVisible = $true
    $tb.AcceptsReturn = $true
    $tb.TextWrapping = 'Wrap'
    $tb.BorderThickness = New-Object System.Windows.Thickness(0)
    $tb.Background = [System.Windows.Media.Brushes]::Transparent
    $tb.Padding = New-Object System.Windows.Thickness(0)
    $tb.SelectionBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(120, 90, 160, 255))
    $tb.SelectionOpacity = 0.55
    $tb.FontSize = [double]$label.size
    $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI, Segoe UI')
    $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(255, 48, 48))
    $tb.MaxWidth = 900
    $tb.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
      Color = [System.Windows.Media.Colors]::Black; BlurRadius = 5; ShadowDepth = 0; Opacity = 0.6
    }
    # The box stays hit-testable so hovering it always gives the I-beam and a drag
    # selects characters, exactly like text anywhere else in Windows.
    $tb.IsHitTestVisible = $true
    $tb.Tag = 'usertext'
    Add-TextCopyHandlers $tb
    [System.Windows.Controls.Canvas]::SetLeft($tb, ([double]$label.x / $script:scale))
    [System.Windows.Controls.Canvas]::SetTop($tb, ([double]$label.y / $script:scale))
    [void]$inkCanvas.Children.Add($tb)
  }
}

# Ctrl+C and Ctrl+A for a read-only text box on the board.
#
# The board window normally owns focus, so a box that merely looks selectable would
# never receive the key. This handler makes the box ask for focus on press and
# copies straight from its selection, so one code path serves both the user's
# labels and the agent's text.
function Add-TextCopyHandlers($box) {
  $box.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    try { [void]$box.Focus() } catch { }
  })
  $box.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::C -and
      (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0)) {
      try {
        if (-not [string]::IsNullOrEmpty($box.SelectedText)) {
          [System.Windows.Clipboard]::SetText($box.SelectedText)
          $e.Handled = $true
        }
      } catch { }
    } elseif ($e.Key -eq [System.Windows.Input.Key]::A -and
      (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0)) {
      $box.SelectAll()
      $e.Handled = $true
    } elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
      $box.Select(0, 0)
      try { [void]$win.Focus() } catch { }
      $e.Handled = $true
    }
  })
}

# Which caret position a point maps to inside a text box.
#
# GetCharacterIndexFromPoint returns the nearest character, not the caret slot the
# way a real text field does. Dragging past the end of a line therefore landed on
# the last character's own index, so the final character never got selected. This
# measures the point against the character's own rectangle and returns the slot
# after it when the pointer is past its midpoint, which is what makes a drag to
# the end select the whole line.
function Get-TextIndexAt($box, $point) {
  $len = $box.Text.Length
  if ($len -le 0) { return 0 }

  # Walk the carets directly instead of trusting GetCharacterIndexFromPoint.
  #
  # That call answers "which character is nearest", which is not the question a
  # drag asks ("which slot am I between"). Using it made the first character
  # unreachable: a point over the first glyph's left half still reported index 0,
  # and any midpoint adjustment then pushed the anchor past it. The caret slots are
  # unambiguous, so they are what this measures against.
  $best = 0
  $bestDistance = [double]::MaxValue
  for ($i = 0; $i -le $len; $i++) {
    $r = $box.GetRectFromCharacterIndex($i, $false)
    if ($r.IsEmpty) { continue }
    # Prefer the caret on the same visual line, then the nearest one horizontally.
    $dy = [Math]::Abs($point.Y - ($r.Top + $r.Height / 2))
    $dx = [Math]::Abs($point.X - $r.Left)
    $score = $dx + $dy * 100
    if ($score -lt $bestDistance) {
      $bestDistance = $score
      $best = $i
    }
  }
  return $best
}

# The TextBox that renders one user text, by its index in the text list.
function Find-TextBox([int]$index) {
  $boxes = @($inkCanvas.Children | Where-Object { $_ -is [System.Windows.Controls.TextBox] })
  if ($index -lt 0 -or $index -ge $boxes.Count) { return $null }
  return $boxes[$index]
}

# Text selection is handled by the TextBox controls themselves. There is no
# hand-painted highlight: a TextBox already selects by character, by word on
# double click, supports Ctrl+A, and copies with Ctrl+C.

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

# Which text a board point falls on, for cursor and press routing.
#
# Returns the TextBox itself rather than an index: the caller needs the box to give
# it focus, and the board holds two separate families of text (the user's labels
# and the agent's marks), so one shared list of boxes is what both resolve against.
function TextBoxAt([double]$x, [double]$y, [double]$r) {
  foreach ($entry in @($script:sceneTexts)) {
    $b = $entry.box
    if ($b -eq $null) { continue }
    $left = [System.Windows.Controls.Canvas]::GetLeft($b)
    $top = [System.Windows.Controls.Canvas]::GetTop($b)
    if ([double]::IsNaN($left)) { $left = 0 }
    if ([double]::IsNaN($top)) { $top = 0 }
    $w = $b.ActualWidth
    $h = $b.ActualHeight
    if ($w -le 0) {
      try {
        $b.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        $w = $b.DesiredSize.Width
        $h = $b.DesiredSize.Height
      } catch { $w = 120; $h = 24 }
    }
    $px = $left * $script:scale
    $py = $top * $script:scale
    $pw = $w * $script:scale
    $ph = $h * $script:scale
    if ($x -ge $px - $r -and $x -le $px + $pw + $r -and $y -ge $py - $r -and $y -le $py + $ph + $r) {
      return $b
    }
  }
  # The user's own labels are laid out on the ink layer by index.
  $idx = Hit-Text $x $y $r
  if ($idx -ge 0) { return Find-TextBox $idx }
  return $null
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
  Hide-Ball
  Render-Ink
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
  $script:activeText = $null
  Close-Editor
  # A text box that keeps focus would swallow the next Esc and leave the board in a
  # half-open state, so focus comes home before the mode is dropped.
  try { [void][System.Windows.Input.Keyboard]::ClearFocus() } catch { }
  try { [void]$win.Focus() } catch { }
  Update-Styles
  Set-Cursor
  Show-Ball
  Render-Ink
  Note 'draw mode off'
}

# --- text hit-testing and the dwell -----------------------------------------
#
# Text on the board is a text-box target, not a picture: resting on it turns the
# pointer into an I-beam and a drag selects. Hit-Text returns the text index in
# grid order, or -1.

function Erase-At([double]$x, [double]$y) {
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
}


# --- the global toggle ------------------------------------------------------
#
# The floating ball is the only way in and out of drawing now: it is on screen all
# the time, unlike a hotkey the user has to remember. These functions remain so a
# mode switch from anywhere still has one spelling.
function Toggle-DrawMode {
  if ($script:mode -eq 'idle') { Enter-DrawMode } else { Exit-DrawMode }
}

# --- the floating ball ------------------------------------------------------
#
# The ball is the user's door onto the board: left-click enters drawing and the
# ball hides; leaving drawing brings it back. Right-click opens the ball's menu.
#
# It is its own always-on-top window for the same reason the island is: the board
# is click-through while idle, so a ball painted on it could never be pressed.
# It stays where the user puts it. It is never auto-hidden: a control that hides
# itself has to be hunted for, and the user asked for the opposite.
$script:ballWindow = $null
# Where the ball sat before the OS began dragging it, so a press that never became
# a drag can put it back exactly.
$script:ballPressLeft = 0.0
$script:ballPressTop = 0.0

$BALL_SIZE = 52
# How much of the ball must stay reachable when it hangs off an edge.
$TUCK_VISIBLE = 16

function Initialize-BallWindow {
  $b = New-Object System.Windows.Window
  $b.WindowStyle = 'None'
  $b.AllowsTransparency = $true
  $b.Background = [System.Windows.Media.Brushes]::Transparent
  $b.ShowInTaskbar = $false
  $b.Topmost = $true
  $b.ShowActivated = $false
  $b.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $b.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
  $b.Width = $BALL_SIZE
  $b.Height = $BALL_SIZE
  $b.Cursor = [System.Windows.Input.Cursors]::Hand
  $b.ToolTip = $script:tr.ball

  $disc = New-Object System.Windows.Controls.Border
  $disc.Width = $BALL_SIZE
  $disc.Height = $BALL_SIZE
  $disc.CornerRadius = New-Object System.Windows.CornerRadius($BALL_SIZE / 2)
  $disc.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(232, 28, 28, 34))
  $disc.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(226, 70, 78))
  $disc.BorderThickness = New-Object System.Windows.Thickness(2)

  # A pencil drawn with shapes, so the ball needs no image asset.
  $pc = New-Object System.Windows.Controls.Canvas
  $pc.Width = $BALL_SIZE
  $pc.Height = $BALL_SIZE
  $body = New-Object System.Windows.Shapes.Rectangle
  $body.Width = 22
  $body.Height = 7
  $body.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(236, 240, 245))
  $body.RadiusX = 2
  $body.RadiusY = 2
  [System.Windows.Controls.Canvas]::SetLeft($body, 14)
  [System.Windows.Controls.Canvas]::SetTop($body, 23)
  $body.RenderTransform = New-Object System.Windows.Media.RotateTransform(-40)
  $body.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
  [void]$pc.Children.Add($body)

  $tip = New-Object System.Windows.Shapes.Polygon
  $tip.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(226, 70, 78))
  $tip.Points = New-Object System.Windows.Media.PointCollection
  [void]$tip.Points.Add((New-Object System.Windows.Point(0, 4)))
  [void]$tip.Points.Add((New-Object System.Windows.Point(7, 0)))
  [void]$tip.Points.Add((New-Object System.Windows.Point(7, 8)))
  [System.Windows.Controls.Canvas]::SetLeft($tip, 10)
  [System.Windows.Controls.Canvas]::SetTop($tip, 22)
  $tip.RenderTransform = New-Object System.Windows.Media.RotateTransform(-40)
  $tip.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
  [void]$pc.Children.Add($tip)

  $disc.Child = $pc
  $b.Content = $disc

  $b.Add_SourceInitialized({
    try {
      $h = New-Object System.Windows.Interop.WindowInteropHelper($script:ballWindow)
      $s = [WpNative]::GetWindowLong($h.Handle, [WpNative]::GWL_EXSTYLE)
      $s = $s -bor [WpNative]::WS_EX_TOOLWINDOW -bor [WpNative]::WS_EX_NOACTIVATE
      [void][WpNative]::SetWindowLong($h.Handle, [WpNative]::GWL_EXSTYLE, $s)
    } catch { }
  })

  # --- dragging, clicking, menu ---
  #
  # Dragging is handed to the OS, which is the only way it stays smooth: a move
  # handled in the dispatcher runs through the interpreter on every pointer event
  # and stutters. Two OS routes were tried, and only one of them works here:
  #
  #   DragMove()        needs a real non-client area (a caption or resize frame).
  #                     This window is WindowStyle=None with no caption, so WPF
  #                     has nothing to grab and the drag silently does nothing.
  #   SC_MOVE           the shell's own "move this window" command. It works on
  #                     any top-level window, including a borderless one.
  #
  # A press still has to be told apart from a drag, so the pointer's travel is
  # measured from press to release.
  $b.Add_MouseLeftButtonDown({
    $press = $_.GetPosition($b)
    $clicks = $_.ClickCount
    $beforeLeft = $script:ballWindow.Left
    $beforeTop = $script:ballWindow.Top
    try {
      $h = (New-Object System.Windows.Interop.WindowInteropHelper($script:ballWindow)).Handle
      # Release the capture WPF takes for a click, or the shell never sees the
      # pointer and the move loop ends immediately.
      [void][WpNative]::ReleaseCapture()
      # Blocks until the user releases the button; the OS moves the window.
      [void][WpNative]::SendMessage($h, [WpNative]::WM_SYSCOMMAND,
        [IntPtr]([WpNative]::SC_MOVE -bor 0x0002), [IntPtr]::Zero)
    } catch {
      Note ("ball: move failed: " + $_.Exception.Message)
    }

    $movedX = [Math]::Abs($script:ballWindow.Left - $beforeLeft)
    $movedY = [Math]::Abs($script:ballWindow.Top - $beforeTop)
    $after = $_.GetPosition($b)
    $travel = [Math]::Max([Math]::Abs($after.X - $press.X), [Math]::Abs($after.Y - $press.Y))

    if (($movedX -gt 2) -or ($movedY -gt 2) -or ($travel -gt 3)) {
      Note 'ball: dragged'
      Clamp-Ball
      return
    }
    # A double click opens the board; a single click only re-seats the ball. The
    # ball is on screen permanently, so a single click has to stay harmless.
    if ($clicks -ge 2) {
      Note 'ball: double click'
      Post-Intent 'ink'
    }
  })

  $b.Add_MouseRightButtonUp({
    Note 'ball: right click'
    Show-BallMenu
  })

  $b.Show()
  $script:ballWindow = $b
  Place-BallFull 40 40
}

# Put the ball at an absolute position in DIPs.
function Place-BallFull([double]$left, [double]$top) {
  if ($script:ballWindow -eq $null) { return }
  $script:ballWindow.Left = [Math]::Round($left)
  $script:ballWindow.Top = [Math]::Round($top)
  $script:ballPressLeft = $script:ballWindow.Left
  $script:ballPressTop = $script:ballWindow.Top
}

# Keep the ball reachable after the OS moved it.
#
# DragMove lets the window go anywhere, including mostly off-screen. This pulls it
# back so at least TUCK_VISIBLE pixels and the whole title area remain on screen:
# a ball dragged out of reach would have to be recovered blind.
function Clamp-Ball {
  if ($script:ballWindow -eq $null) { return }
  $screenLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
  $screenTop = [System.Windows.SystemParameters]::VirtualScreenTop
  $screenW = [System.Windows.SystemParameters]::VirtualScreenWidth
  $screenH = [System.Windows.SystemParameters]::VirtualScreenHeight

  $minLeft = $screenLeft - ($BALL_SIZE - $TUCK_VISIBLE)
  $maxLeft = $screenLeft + $screenW - $TUCK_VISIBLE
  $minTop = $screenTop
  $maxTop = $screenTop + $screenH - $TUCK_VISIBLE

  $l = [Math]::Max($minLeft, [Math]::Min($maxLeft, $script:ballWindow.Left))
  $t = [Math]::Max($minTop, [Math]::Min($maxTop, $script:ballWindow.Top))
  Place-BallFull $l $t
}

function Hide-Ball {
  if ($script:ballWindow -ne $null) { try { $script:ballWindow.Hide() } catch { } }
}

function Show-Ball {
  if ($script:ballWindow -eq $null) {
    try { Initialize-BallWindow } catch { Note ("ball init failed: " + $_.Exception.Message); return }
  }
  try { $script:ballWindow.Show() } catch { }
  Note 'ball shown'
}

# The ball's menu. Two entries only: the ball sits outside the board, so "exit
# drawing" is not something it can do, and the text tool needs the board open.
$script:ballMenu = $null

function New-BallMenu {
  $m = New-Object System.Windows.Forms.ContextMenuStrip
  $call = New-Object System.Windows.Forms.ToolStripMenuItem($script:tr.call)
  $clear = New-Object System.Windows.Forms.ToolStripMenuItem($script:tr.clear)

  $call.add_Click({ Post-Intent 'call' })
  $clear.add_Click({ Post-Intent 'clear' })

  [void]$m.Items.Add($call)
  [void]$m.Items.Add($clear)
  return $m
}

function Show-BallMenu {
  try {
    if ($script:ballMenu -eq $null) { $script:ballMenu = New-BallMenu }
    $script:ballMenu.Show([System.Windows.Forms.Cursor]::Position)
    Note 'ball menu shown'
  } catch {
    Note ("ball menu failed: " + $_.Exception.Message)
  }
}

# --- the board menu ---------------------------------------------------------
#
# Right-click inside the board opens the same three actions, plus the text tool.
# This is a separate ContextMenuStrip instance from the ball's: the two show from
# different windows, and one strip cannot be anchored to both.
$script:boardMenu = $null

function New-BoardMenu {
  $board = New-Object System.Windows.Forms.ContextMenuStrip
  $text = New-Object System.Windows.Forms.ToolStripMenuItem($script:tr.textBox)
  $call = New-Object System.Windows.Forms.ToolStripMenuItem($script:tr.call)
  $clear = New-Object System.Windows.Forms.ToolStripMenuItem($script:tr.clear)
  $exitDraw = New-Object System.Windows.Forms.ToolStripMenuItem($script:tr.exitDraw)

  $text.add_Click({ Post-Intent 'text' })
  $call.add_Click({ Post-Intent 'call' })
  $clear.add_Click({ Post-Intent 'clear' })
  $exitDraw.add_Click({ Post-Intent 'idle' })

  # No text tool entry: text is always selectable, so there is nothing to turn on.
  [void]$board.Items.Add($text)
  [void]$board.Items.Add($call)
  [void]$board.Items.Add($clear)
  [void]$board.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  [void]$board.Items.Add($exitDraw)
  return $board
}

function Show-BoardMenu([double]$x, [double]$y) {
  try {
    if ($script:boardMenu -eq $null) { $script:boardMenu = New-BoardMenu }
    $script:boardMenu.Show([System.Windows.Forms.Cursor]::Position)
    Note 'board menu shown'
  } catch {
    Note ("board menu failed: " + $_.Exception.Message)
  }
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
# The board's menu drops an editor where the pointer is. Enter inserts a line
# break; clicking anywhere outside commits; Esc drops it. The text survives as a
# red label on the board and travels to the agent in user.json, so "what the user
# means" can be written, not only drawn.
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
  # Enter must insert a newline, so the box has to accept returns; commit happens
  # on a click outside instead.
  $box.AcceptsReturn = $true
  $box.TextWrapping = 'Wrap'
  $box.VerticalScrollBarVisibility = 'Auto'
  $box.MaxHeight = 320
  $box.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI, Segoe UI')
  $border.Child = $box

  [System.Windows.Controls.Canvas]::SetLeft($border, ($x / $script:scale))
  [System.Windows.Controls.Canvas]::SetTop($border, ($y / $script:scale))
  [void]$inkCanvas.Children.Add($border)
  $script:editor = [pscustomobject]@{ border = $border; box = $box; x = $x; y = $y }

  $box.Add_KeyDown({
    param($s, $e)
    # Only Esc ends editing here. Enter falls through to the TextBox, which turns
    # it into a line break.
    if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
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
  # A box holding only whitespace and stray newlines is not content.
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  $script:strokeSeq++
  [void]$script:texts.Add([pscustomobject]@{
    id = ("t{0}-{1}" -f $script:strokeSeq, [DateTime]::UtcNow.Ticks)
    x = $x; y = $y; size = 18; text = $text.TrimEnd()
  })
  $script:userRev++
  Render-Ink
  Save-User
  Note 'text committed'
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

# --- window events ----------------------------------------------------------
$win.Add_PreviewMouseLeftButtonDown({
  if ($script:mode -eq 'idle') { return }

  # Clicking outside the open text box commits it, the way every other editor
  # behaves. Clicks inside the box are swallowed by the box itself.
  if ($script:editor -ne $null) {
    Commit-Editor
    return
  }

  $p = $_.GetPosition($win)
  $x = $p.X * $script:scale; $y = $p.Y * $script:scale

  # Shift+left-click is the eraser now that the right button opens the menu.
  if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0) {
    $script:activePoints = $null
    $script:activeErase = $true
    Erase-At $x $y
    return
  }

  # Text is a container, and that goes for the agent's text as much as the user's.
  # The board owns the mouse, so it takes the press and drives the box's selection
  # itself; nothing here is drawn.
  #
  # The press is marked handled: the box is focused but must not run its own drag
  # loop, or the two would fight over the selection and the pointer would never
  # reach the board's move handler.
  $box = TextBoxAt $x $y 6
  if ($box -ne $null) {
    $script:activePoints = $null
    $script:activeText = $box
    $_.Handled = $true
    try {
      [void]$box.Focus()
      [void][System.Windows.Input.Keyboard]::Focus($box)
      # Anchor the selection at the caret slot under the press.
      $local = $box.PointFromScreen($win.PointToScreen((New-Object System.Windows.Point($p.X, $p.Y))))
      $idx = Get-TextIndexAt $box $local
      $script:selectBase = $idx
      $box.Select($idx, 0)
    } catch { $script:selectBase = 0 }
    return
  }

  $script:activePoints = New-Object System.Collections.ArrayList
  [void]$script:activePoints.Add(@($x, $y))
})

$win.Add_PreviewMouseMove({
  if ($script:mode -eq 'idle') { return }
  $p = $_.GetPosition($win)
  $x = $p.X * $script:scale; $y = $p.Y * $script:scale

  # The crosshair is repainted every move: WPF resets the cursor on each
  # WM_SETCURSOR and a transparent host window can skip that round trip.
  #
  # Text is a live container, not a picture: hovering it must show the I-beam, and
  # that is measured here rather than left to the TextBox because the board window
  # owns the pointer for drawing.
  $overText = ((TextBoxAt $x $y 6) -ne $null)
  $idc = if ($overText) { [WpNative]::IDC_IBEAM } else { [WpNative]::IDC_CROSS }
  if ($script:activePoints -eq $null -and -not $script:activeErase) {
    try { [void][WpNative]::SetCursor([WpNative]::LoadCursor([IntPtr]::Zero, $idc)) } catch { }
  }

  # A drag that began on text belongs to that text: move the selection the way the
  # box would if it were receiving the pointer itself. The board has to do this
  # because it owns the mouse while drawing, and the text boxes sit underneath the
  # ink layer.
  if ($script:activeText -ne $null) {
    $_.Handled = $true
    try {
      if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        $local = $script:activeText.PointFromScreen($win.PointToScreen((New-Object System.Windows.Point($p.X, $p.Y))))
        $idx = Get-TextIndexAt $script:activeText $local
        $a = [Math]::Min($script:selectBase, $idx)
        $b = [Math]::Max($script:selectBase, $idx)
        $script:activeText.Select($a, $b - $a)
      }
    } catch { }
    return
  }

  if ($script:activeErase) {
    Erase-At $x $y
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

$win.Add_PreviewMouseLeftButtonUp({
  # The selection lives in the box; the drag is over, so let the board draw again.
  if ($script:activeText -ne $null) {
    $script:activeText = $null
    return
  }
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

$win.Add_PreviewMouseRightButtonDown({
  if ($script:mode -eq 'idle') { return }
  # The right button only opens the menu; erasing moved to Shift+left-click.
  $script:activeErase = $false
  $script:activePoints = $null
  if ($script:editor -ne $null) { Commit-Editor }
  # Record where the menu was opened: "Text box" drops its editor here, so the
  # user types exactly where they clicked instead of at a fixed corner.
  $p = $_.GetPosition($win)
  $script:menuAtX = $p.X * $script:scale
  $script:menuAtY = $p.Y * $script:scale
  Show-BoardMenu $script:menuAtX $script:menuAtY
})

$win.Add_MouseWheel({
  if ($script:mode -eq 'idle') { return }
  $step = if ($_.Delta -gt 0) { 1 } else { -1 }
  $script:width = [Math]::Max($MIN_WIDTH, [Math]::Min($MAX_WIDTH, $script:width + $step))
  $p = $_.GetPosition($win)
  Show-Badge ($p.X * $script:scale) ($p.Y * $script:scale)
})

# Esc is handled at the tunnel stage so it works no matter who holds focus.
#
# Once a text box has focus the key never bubbles back to the window, and leaving
# drawing mode from a state the user cannot see (focus parked in an invisible read-
# only box) is exactly how the ball failed to come back last time.
$win.Add_PreviewKeyDown({
  if ($_.Key -ne [System.Windows.Input.Key]::Escape) { return }
  if ($script:editor -ne $null) {
    $_.Handled = $true
    Close-Editor
    return
  }
  if ($script:mode -ne 'idle') {
    $_.Handled = $true
    Exit-DrawMode
  }
})

$win.Add_KeyDown({
  if ($_.Key -eq [System.Windows.Input.Key]::Escape) {
    if ($script:editor -ne $null) { Close-Editor; return }
    Exit-DrawMode
  }
})

$win.Add_Closed({
  try { if ($script:ballMenu -ne $null) { $script:ballMenu.Close() } } catch { }
  try { if ($script:boardMenu -ne $null) { $script:boardMenu.Close() } } catch { }
  try { if ($script:ballWindow -ne $null) { $script:ballWindow.Close() } } catch { }
  try { Remove-Item -LiteralPath $Window -Force -ErrorAction SilentlyContinue } catch { }
})
# --- timers -----------------------------------------------------------------
$ticker = New-Object System.Windows.Threading.DispatcherTimer
$ticker.Interval = [TimeSpan]::FromMilliseconds($POLL_MS)
$ticker.Add_Tick({
  try {
    # Menu intents run here, on the dispatcher: this is the only thread that may
    # touch the window's styles or its cursor.
    $want = Take-Intent
    if ($want -ne $null) {
      Note ("apply intent: " + $want)
      switch ($want) {
        'ink'   { Enter-DrawMode }
        'idle'  { Exit-DrawMode }
        'clear' { Clear-All }
        'call'  { Summon-Agent }
        # "Text box" drops an editor where the menu was opened. The position is
        # fixed when the menu appears rather than read here: by the time the click
        # is processed the pointer has moved onto the menu item.
        'text'  {
          $wasOpen = ($script:mode -ne 'idle')
          Enter-DrawMode
          $tx = if ($script:menuAtX -ne $null) { [double]$script:menuAtX } else { 200.0 }
          $ty = if ($script:menuAtY -ne $null) { [double]$script:menuAtY } else { 200.0 }
          Open-Editor $tx $ty
          if (-not $wasOpen) { Note 'text: opened from the ball, editor placed at default' }
        }
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
    Update-Island
    Update-IslandHover
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
  # The ball replaces the tray and the hotkey: it is the only door onto the board,
  # so it comes up with the window and stays up.
  Show-Ball
  Note ("loaded scale=" + $script:scale)
})

[void]$win.ShowDialog()
try { if ($script:ballWindow -ne $null) { $script:ballWindow.Close() } } catch { }
try { Remove-Item -LiteralPath $Window -Force -ErrorAction SilentlyContinue } catch { }
exit 0
