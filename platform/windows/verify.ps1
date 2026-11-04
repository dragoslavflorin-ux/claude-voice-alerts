# Checks the installed alert windows: adds a silent test alert per part, measures where its window appears
# (monitor, corner, margin), checks it does not take focus, removes it and checks the hub exits.
# Exit code = number of failed checks.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('CvaVerify' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class CvaVerify {
    public struct RECT { public int L, T, R, B; }
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EP cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(System.Drawing.Point p, uint f);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr m, int t, out uint x, out uint y);
    public static IntPtr Find(uint pid, string title) {
        IntPtr r = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr x) { uint p; GetWindowThreadProcessId(h, out p); var s = new StringBuilder(256); GetWindowText(h, s, 256);
            if (p == pid && IsWindowVisible(h) && s.ToString() == title) { r = h; return false; } return true; }, IntPtr.Zero);
        return r;
    }
}
'@
}
[void][CvaVerify]::SetProcessDpiAwarenessContext([IntPtr](-4))
$cfg = Get-CvaConfig
$loc = Get-CvaLocale $cfg.language
$state = Get-CvaStateDir $cfg
$script:ok = 0; $script:bad = 0
function Check([bool]$c, [string]$t) { if ($c) { $script:ok++; "OK     $t" } else { $script:bad++; "FAIL   $t" } }

function Expected-Screen([string]$Part) {
    $all = [System.Windows.Forms.Screen]::AllScreens
    switch ("$($cfg.$Part.monitor)") {
        'leftmost' { return ($all | Sort-Object { $_.Bounds.X } | Select-Object -First 1) }
        'rightmost' { return ($all | Sort-Object { $_.Bounds.Right } | Select-Object -Last 1) }
        'app' {
            if ($Part -eq 'cowork') {
                $p = Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and "$($_.Path)" -notlike '*node_modules*' } | Select-Object -First 1
                if ($p) { return [System.Windows.Forms.Screen]::FromHandle($p.MainWindowHandle) }
            }
            return $null   # Claude Code: monitor of the session window, not known for a test alert
        }
        default { return [System.Windows.Forms.Screen]::PrimaryScreen }
    }
}

foreach ($part in @($cfg.parts)) {
    $title = if ($part -eq 'code') { "$($loc.ui.code_title)" } else { "$($loc.ui.cowork_title)" }
    "${part}:"
    $audio = @(Get-ChildItem (Join-Path $script:CvaRoot 'audio') -Filter "$part-*" -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.mp3', '.wav' })
    Check ($audio.Count -ge 2) "audio files ($($audio.Name -join ', '))"
    $id = "verify-$PID-$part"
    $fg0 = [CvaVerify]::GetForegroundWindow()
    Add-CvaAlert $cfg $part $id 'done' 'install-check' @{ silent = $true }
    $h = [IntPtr]::Zero; $hubPid = 0
    for ($i = 0; $i -lt 40 -and $h -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 250
        $hp = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*hub.ps1*' } | Select-Object -First 1
        if ($hp) { $hubPid = $hp.ProcessId; $h = [CvaVerify]::Find([uint32]$hubPid, $title) }
    }
    if ($h -eq [IntPtr]::Zero) { Check $false "window '$title' did not appear"; [void](Remove-CvaAlert $cfg $part $id); continue }
    Start-Sleep -Milliseconds 400
    $r = New-Object CvaVerify+RECT; [void][CvaVerify]::GetWindowRect($h, [ref]$r)
    $rect = New-Object System.Drawing.Rectangle($r.L, $r.T, ($r.R - $r.L), ($r.B - $r.T))
    $scr = [System.Windows.Forms.Screen]::FromRectangle($rect)
    $exp = Expected-Screen $part
    if ($exp) { Check ($scr.DeviceName -eq $exp.DeviceName) "monitor $($scr.DeviceName) (expected $($exp.DeviceName), setting '$($cfg.$part.monitor)')" }
    $dx = [uint32]96; $dy = [uint32]96
    $c = New-Object System.Drawing.Point(($scr.Bounds.X + [int]($scr.Bounds.Width / 2)), ($scr.Bounds.Y + [int]($scr.Bounds.Height / 2)))
    [void][CvaVerify]::GetDpiForMonitor([CvaVerify]::MonitorFromPoint($c, 2), 0, [ref]$dx, [ref]$dy)
    $m = [int][Math]::Round([int]$cfg.margin_px * $dx / 96.0)
    $wa = $scr.WorkingArea; $corner = "$($cfg.$part.corner)"
    $gx = if ($corner -like '*right') { $wa.Right - $r.R } else { $r.L - $wa.Left }
    $gy = if ($corner -like 'top*') { $r.T - $wa.Top } else { $wa.Bottom - $r.B }
    Check ([Math]::Abs($gx - $m) -le 1 -and [Math]::Abs($gy - $m) -le 1) "corner $corner, gaps $gx/$gy px (expected $m at $([int]($dx / 96 * 100))%), rect L=$($r.L) T=$($r.T) R=$($r.R) B=$($r.B)"
    $ex = [CvaVerify]::GetWindowLong($h, -20)
    Check ((($ex -band 0x08000000) -ne 0) -and (($ex -band 8) -ne 0) -and ([CvaVerify]::GetForegroundWindow() -ne $h)) 'always on top, never takes focus'
    [void](Remove-CvaAlert $cfg $part $id)
}
if (@(Get-ChildItem -LiteralPath (Join-Path $state 'alerts') -Filter '*.json' -ErrorAction SilentlyContinue).Count -gt 0) { 'SKIP   hub exit check: real alerts are pending'; "VERIFY: $script:ok OK, $script:bad failed"; exit $script:bad }
$gone = $false
for ($i = 0; $i -lt 30 -and -not $gone; $i++) { Start-Sleep -Milliseconds 250; $gone = -not (Test-CvaHubRunning) }
Check $gone 'hub exits when no alert is left'
"VERIFY: $script:ok OK, $script:bad failed"
exit $script:bad
