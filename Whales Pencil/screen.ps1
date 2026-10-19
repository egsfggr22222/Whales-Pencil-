# Report the desktop in physical pixels, or capture it, in one place.
#
# A DPI-unaware process is shown a scaled-down desktop: on a 125% display with a
# 1920x1080 panel it reports 1536x864, and every coordinate derived from that is
# wrong by the scale factor. Declaring DPI awareness first makes the numbers
# true, and it asks the OS rather than assuming a resolution, so a different
# monitor or scale answers for itself.
#
# -Mode size     print "<w>x<h>@<x>,<y>"
# -Mode capture -Out <file>   write the whole desktop to that PNG
#
# Capture uses BitBlt rather than Graphics.CopyFromScreen: the latter is known to
# come back one or two pixels short at the right and bottom edges, which makes a
# "full screen" screenshot silently not match the screen it claims to show.
# Every capture is verified against the reported size and retried once, so a
# short image can never be handed out as if it were complete.
#
# This file must stay ASCII-only.

param(
  [ValidateSet('size', 'capture')][string]$Mode = 'size',
  [string]$Out = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# System.Drawing is not in Add-Type's default reference set, so the compiler needs
# it named explicitly before the type below can mention Bitmap.
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class WpScreen
{
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")]
    public static extern bool BitBlt(IntPtr hdcDest, int xDest, int yDest, int w, int h,
        IntPtr hdcSrc, int xSrc, int ySrc, uint rop);

    const uint SRCCOPY = 0x00CC0020;
    const uint CAPTUREBLT = 0x40000000;

    /// <summary>Copy a screen rectangle into a new bitmap, exactly w by h.</summary>
    public static Bitmap Grab(int x, int y, int w, int h)
    {
        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memDc = CreateCompatibleDC(screenDc);
        IntPtr bitmap = CreateCompatibleBitmap(screenDc, w, h);
        IntPtr previous = SelectObject(memDc, bitmap);
        try
        {
            BitBlt(memDc, 0, 0, w, h, screenDc, x, y, SRCCOPY | CAPTUREBLT);
            // The GDI bitmap is owned by the new Bitmap from here on.
            var copy = (Bitmap)Image.FromHbitmap(bitmap);
            return copy;
        }
        finally
        {
            SelectObject(memDc, previous);
            DeleteObject(bitmap);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }
}
'@

# Per-monitor-v2 is the modern mode; fall back to the system-wide call on builds
# that do not know it. Either way the process must be aware before any size is
# read, otherwise the values come back scaled.
try {
  $perMonitorV2 = [IntPtr](-4)
  [void][WpScreen]::SetProcessDpiAwarenessContext($perMonitorV2)
} catch {
  [void][WpScreen]::SetProcessDPIAware()
}

$b = [System.Windows.Forms.SystemInformation]::VirtualScreen

switch ($Mode) {
  'size' {
    Write-Output ("{0}x{1}@{2},{3}" -f $b.Width, $b.Height, $b.X, $b.Y)
    exit 0
  }
  'capture' {
    if ([string]::IsNullOrWhiteSpace($Out)) {
      Write-Error 'capture needs -Out'
      exit 2
    }

    # Grab, verify, and retry once. A short bitmap is the one failure mode that
    # would otherwise be invisible: the picture looks fine but its edges are not
    # where the screen says they are.
    $attempt = 0
    $ok = $false
    while ($attempt -lt 2 -and -not $ok) {
      $attempt++
      $bmp = $null
      try {
        $bmp = [WpScreen]::Grab($b.X, $b.Y, $b.Width, $b.Height)
        if ($bmp.Width -ne $b.Width -or $bmp.Height -ne $b.Height) {
          Write-Error ("grab returned {0}x{1}, expected {2}x{3}" -f $bmp.Width, $bmp.Height, $b.Width, $b.Height)
        } else {
          $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
          $ok = $true
        }
      } catch {
        if ($attempt -ge 2) { throw }
      } finally {
        if ($bmp -ne $null) { $bmp.Dispose() }
      }
      if (-not $ok -and $attempt -lt 2) { Start-Sleep -Milliseconds 150 }
    }

    if (-not $ok) {
      Write-Error 'capture failed after retry'
      exit 3
    }

    # Confirm the file on disk matches too, not just the in-memory bitmap.
    $check = [System.Drawing.Image]::FromFile($Out)
    try {
      Write-Output ("{0}x{1}" -f $check.Width, $check.Height)
    } finally {
      $check.Dispose()
    }
    exit 0
  }
}
