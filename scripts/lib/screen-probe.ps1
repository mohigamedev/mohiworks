# Screen probe: what actually reaches the screen, not what the title drew.
# Grabs the title's window from the desktop $Count times and reports, per
# grab, the mean brightness of a sampled grid and a hash of it. Frames the
# title rendered identically that grab differently (dark grabs, partial
# grabs) are presentation faults: flicker the captured frames cannot show.
# Windows PowerShell 5.1; dot-source it, then call Measure-Screen.

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ScreenProbeWin32 {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@

function Measure-Screen {
    param([int]$Count = 60, [int]$IntervalMs = 25, [string]$Process = 'victory')
    [ScreenProbeWin32]::SetProcessDPIAware() | Out-Null
    $p = Get-Process $Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { throw "no window of $Process" }
    $r = New-Object ScreenProbeWin32+RECT
    [ScreenProbeWin32]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
    # The client area, roughly: skip the frame and the caption.
    $x = $r.Left + 10; $y = $r.Top + 40
    $w = [math]::Max(64, $r.Right - $r.Left - 20); $h = [math]::Max(64, $r.Bottom - $r.Top - 50)
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $grabs = @()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Count; $i++) {
        $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size)
        $sum = 0; $n = 0; $sig = New-Object System.Text.StringBuilder
        for ($sy = 0; $sy -lt 16; $sy++) {
            for ($sx = 0; $sx -lt 16; $sx++) {
                $c = $bmp.GetPixel([int](($sx + 0.5) * $w / 16), [int](($sy + 0.5) * $h / 16))
                $v = [int](($c.R + $c.G + $c.B) / 3)
                $sum += $v; $n++
                [void]$sig.Append([char](65 + [int]($v / 16)))
            }
        }
        $grabs += [pscustomobject]@{ Ms = $watch.ElapsedMilliseconds; Mean = [math]::Round($sum / $n, 1); Sig = $sig.ToString() }
        Start-Sleep -Milliseconds $IntervalMs
    }
    $g.Dispose(); $bmp.Dispose()
    $common = ($grabs | Group-Object Sig | Sort-Object Count -Descending | Select-Object -First 1).Name
    $odd = @($grabs | Where-Object { $_.Sig -ne $common })
    [pscustomobject]@{
        Window   = "$w x $h at $x,$y"
        Grabs    = $grabs.Count
        Seconds  = [math]::Round($watch.ElapsedMilliseconds / 1000, 1)
        Distinct = @($grabs | Group-Object Sig).Count
        Odd      = $odd.Count
        MeanMin  = ($grabs | Measure-Object Mean -Minimum).Minimum
        MeanMax  = ($grabs | Measure-Object Mean -Maximum).Maximum
        OddMeans = ($odd | ForEach-Object { $_.Mean }) -join ','
        Means    = @($grabs | ForEach-Object { $_.Mean })
        # Changes of direction bigger than 1 between grabs: a fade or an
        # animation has few; stale frames shown between new ones make many.
        Reversals = $(
            $v = @($grabs | ForEach-Object { $_.Mean }); $n = 0
            for ($i = 2; $i -lt $v.Count; $i++) {
                $a = $v[$i - 1] - $v[$i - 2]; $b = $v[$i] - $v[$i - 1]
                if ([math]::Abs($a) -gt 1 -and [math]::Abs($b) -gt 1 -and ($a * $b) -lt 0) { $n++ }
            }
            $n
        )
    }
}
