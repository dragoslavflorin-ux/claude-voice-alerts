# Alert hub: ONE process for all alerts. Reads <state>\alerts\*.json (written by hooks and the Cowork watcher),
# shows one window per part (Claude Code, Cowork) with one row per alert, plays the voices (never two at once),
# and exits when the list is empty. Click a row: dismiss it and bring its window to front.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')

$mutexName = 'Local\ClaudeVoiceAlertsHub'
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$created)
if (-not $created) { exit 0 }

try {
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, PresentationCore, WindowsBase, UIAutomationClient, UIAutomationTypes
if (-not ('CvaForm' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Text; using System.Collections.Generic;
using System.Runtime.InteropServices; using System.Windows.Forms;
public class CvaForm : Form {
    public CvaForm() { DoubleBuffered = true; }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008; return cp; }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0021) { m.Result = (IntPtr)3; return; }   // WM_MOUSEACTIVATE: never take focus
        if (m.Msg == 0x02E0) { m.Result = IntPtr.Zero; return; } // WM_DPICHANGED: we size ourselves per monitor
        base.WndProc(ref m);
    }
}
public static class CvaNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(System.Drawing.Point p, uint f);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr m, int t, out uint x, out uint y);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint c);
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EP cb, IntPtr l);
    public static string Title(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
    // visible top-level windows of the given processes
    public static List<IntPtr> WindowsOf(HashSet<uint> pids) {
        var l = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr x) { uint p; GetWindowThreadProcessId(h, out p);
            if (pids.Contains(p) && IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero && Title(h).Length > 0) l.Add(h); return true; }, IntPtr.Zero);
        return l;
    }
    public static void Activate(IntPtr h) {
        if (IsIconic(h)) ShowWindow(h, 9);
        keybd_event(0x12, 0, 0, UIntPtr.Zero); SetForegroundWindow(h); keybd_event(0x12, 0, 2, UIntPtr.Zero);
    }
}
'@
}
if (-not [CvaNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [void][CvaNative]::SetProcessDPIAware() }
[System.Windows.Forms.Application]::EnableVisualStyles()

$cfg = Get-CvaConfig
$loc = Get-CvaLocale $cfg.language
$state = Get-CvaStateDir $cfg
$alertsDir = Join-Path $state 'alerts'
$audioDir = Join-Path $script:CvaRoot 'audio'
$parts = @('code', 'cowork')
$titles = @{ code = "$($loc.ui.code_title)"; cowork = "$($loc.ui.cowork_title)" }

# ---------------------------------------------------------------- voice
function Get-AudioInfo([string]$Part, [string]$Kind) {
    foreach ($ext in 'mp3', 'wav') {
        $f = Join-Path $audioDir "$Part-$Kind.$ext"
        if (Test-Path -LiteralPath $f) {
            $len = (Get-Item -LiteralPath $f).Length
            # edge-tts MP3 is 48 kbit/s CBR; WAV from SAPI/ffmpeg is PCM (bytes per second in the header)
            $ms = if ($ext -eq 'mp3') { [int]($len * 8 / 48000 * 1000) } else {
                $b = [IO.File]::ReadAllBytes($f); $bps = [BitConverter]::ToInt32($b, 28); [int](($len - 44) / [Math]::Max(1, $bps) * 1000) }
            return @{ file = $f; ms = [Math]::Max(500, $ms); ext = $ext }
        }
    }
    return $null
}
$audio = @{}
foreach ($p in $parts) { foreach ($k in 'done', 'needs') { $audio["$p-$k"] = Get-AudioInfo $p $k } }
$script:mp = New-Object System.Windows.Media.MediaPlayer
$script:sp = New-Object System.Media.SoundPlayer
function Play-Audio($a) {
    try {
        if ($a.ext -eq 'mp3') { $script:mp.Open([Uri]$a.file); $script:mp.Volume = 1.0; $script:mp.Play() }
        else { $script:sp.SoundLocation = $a.file; $script:sp.Play() }
    } catch { Write-CvaLog 'hub' "audio error $($a.file): $_" }
}
function Stop-Audio { try { $script:mp.Stop(); $script:sp.Stop() } catch { } }
$voice = @{ playingUntil = [DateTime]::MinValue; lastEnd = @{ code = [DateTime]::MinValue; cowork = [DateTime]::MinValue }; limitLogged = @{} }

# ---------------------------------------------------------------- windows to bring to front
function Get-ClaudeWindow {
    foreach ($p in Get-Process claude -ErrorAction SilentlyContinue) {
        if ($p.MainWindowHandle -ne [IntPtr]::Zero -and "$($p.Path)" -notlike '*node_modules*' -and "$($p.Path)" -notlike '*\.local\*') { return $p.MainWindowHandle }
    }
    return [IntPtr]::Zero
}
$focusCache = @{}
function Get-CodeWindow($e) {
    if ($focusCache.ContainsKey($e.id)) { $h = $focusCache[$e.id]; if ([CvaNative]::IsWindow($h)) { return $h } }
    $h = [IntPtr]::Zero
    if ($e.console_window) { $c = [IntPtr][long]$e.console_window; if ([CvaNative]::IsWindow($c) -and [CvaNative]::IsWindowVisible($c)) { $h = $c } }
    if ($h -eq [IntPtr]::Zero -and $e.host_exe) {
        $pids = New-Object 'System.Collections.Generic.HashSet[uint32]'
        foreach ($p in Get-Process -Name $e.host_exe -ErrorAction SilentlyContinue) { [void]$pids.Add([uint32]$p.Id) }
        $wins = [CvaNative]::WindowsOf($pids)
        # editors put the workspace folder in the title: match the deepest folder of cwd that appears in a title
        $segs = @("$($e.cwd)" -split '[\\/]' | Where-Object { $_ })
        [array]::Reverse($segs)
        foreach ($s in $segs) { foreach ($w in $wins) { if ([CvaNative]::Title($w) -like "*$s*") { $h = $w; break } }; if ($h -ne [IntPtr]::Zero) { break } }
        if ($h -eq [IntPtr]::Zero -and $wins.Count) { $h = $wins[0] }
    }
    if ($h -eq [IntPtr]::Zero) { $h = Get-ClaudeWindow }   # Claude Code inside the desktop app
    $focusCache[$e.id] = $h
    return $h
}
function Open-CoworkConversation([string]$Title) {
    $w = Get-ClaudeWindow
    if ($w -eq [IntPtr]::Zero) { return }
    [CvaNative]::Activate($w)
    try {
        $A = [System.Windows.Automation.AutomationElement]
        $cond = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)),
            (New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, $Title)))
        $t = $A::FromHandle($w).FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
        for ($el = $t; $el; $el = $walker.GetParent($el)) {
            if ($el.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button) {
                $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Write-CvaLog 'hub' "opened conversation [$Title]"; break
            }
        }
    } catch { Write-CvaLog 'hub' "could not open conversation [$Title]: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- placement
function Get-TargetScreen([string]$Part, $Newest) {
    $all = [System.Windows.Forms.Screen]::AllScreens
    $mode = "$($cfg.$Part.monitor)"
    switch ($mode) {
        'primary' { return [System.Windows.Forms.Screen]::PrimaryScreen }
        'leftmost' { return ($all | Sort-Object { $_.Bounds.X } | Select-Object -First 1) }
        'rightmost' { return ($all | Sort-Object { $_.Bounds.Right } | Select-Object -Last 1) }
        'app' {
            $h = if ($Part -eq 'cowork') { Get-ClaudeWindow } elseif ($Newest) { Get-CodeWindow $Newest } else { [IntPtr]::Zero }
            if ($h -ne [IntPtr]::Zero) { return [System.Windows.Forms.Screen]::FromHandle($h) }
            return [System.Windows.Forms.Screen]::PrimaryScreen
        }
        default { if ($mode -match '^\d+$' -and [int]$mode -lt $all.Count) { return $all[[int]$mode] }; return [System.Windows.Forms.Screen]::PrimaryScreen }
    }
}
function Get-ScreenScale($scr) {
    $c = New-Object System.Drawing.Point(($scr.Bounds.X + [int]($scr.Bounds.Width / 2)), ($scr.Bounds.Y + [int]($scr.Bounds.Height / 2)))
    $dx = [uint32]96; $dy = [uint32]96
    try { [void][CvaNative]::GetDpiForMonitor([CvaNative]::MonitorFromPoint($c, 2), 0, [ref]$dx, [ref]$dy) } catch { }
    return ($dx / 96.0)
}

# ---------------------------------------------------------------- drawing
$colBg = [System.Drawing.Color]::FromArgb(0, 14, 53)
$colText = [System.Drawing.Color]::FromArgb(247, 245, 238)
$colDim = [System.Drawing.Color]::FromArgb(150, 160, 190)
$colLine = [System.Drawing.Color]::FromArgb(40, 52, 95)
$colNeeds = [System.Drawing.Color]::FromArgb(255, 196, 0)
$colDone = [System.Drawing.Color]::FromArgb(80, 200, 120)
$colBtn = [System.Drawing.Color]::FromArgb(255, 18, 0)
$fontCache = @{}
function Get-Font([double]$Pt, [bool]$Bold, [double]$S) {
    $k = "$Pt|$Bold|$S"
    if (-not $fontCache.ContainsKey($k)) {
        $st = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
        $fontCache[$k] = New-Object System.Drawing.Font('Segoe UI', [single]($Pt * 96 / 72 * $S), $st, [System.Drawing.GraphicsUnit]::Pixel)
    }
    return $fontCache[$k]
}
$TF = [System.Windows.Forms.TextFormatFlags]
function Get-Age([long]$CreatedMs) {
    $min = [int][Math]::Floor(((Get-CvaUnixMs) - $CreatedMs) / 60000)
    if ($min -lt 1) { return "$($loc.ui.just_now)" }
    if ($min -lt 60) { return ("$($loc.ui.minutes_ago)" -replace '\{n\}', $min) }
    return ("$($loc.ui.hours_ago)" -replace '\{n\}', [int][Math]::Floor($min / 60))
}
function Get-Message([string]$Part, [string]$Kind) {
    $t = "$($cfg.$Part.$Kind)"
    if (-not $t) { $t = "$($loc.presets.$($cfg.tone).$Part.$Kind)" }
    return $t
}

# Builds the layout of one window: list of items with rectangles (physical pixels)
function Build-Layout([string]$Part, $Entries, [double]$S) {
    function P([double]$v) { [int][Math]::Round($v * $S) }
    $W = P 340; $pad = P 14
    $items = New-Object System.Collections.Generic.List[object]
    $y = P 10
    $items.Add(@{ type = 'header'; rect = (New-Object System.Drawing.Rectangle($pad, $y, ($W - 2 * $pad), (P 18))); text = $titles[$Part] })
    $y += P 24
    $maxRows = [Math]::Max(1, [int]$cfg.max_rows)
    $shown = @($Entries | Select-Object -First $maxRows)
    $fProj = Get-Font 11 $true $S; $fMsg = Get-Font 10 $false $S
    foreach ($e in $shown) {
        $msg = Get-Message $Part $e.kind
        $msgW = $W - 2 * $pad - (P 10)
        $h = [System.Windows.Forms.TextRenderer]::MeasureText($msg, $fMsg, (New-Object System.Drawing.Size($msgW, 2000)), ($TF::WordBreak -bor $TF::NoPadding)).Height
        $h = [Math]::Min($h, 2 * $fMsg.Height + (P 2))
        $rowH = (P 6) + $fProj.Height + (P 2) + $h + (P 8)
        $items.Add(@{ type = 'row'; rect = (New-Object System.Drawing.Rectangle(0, $y, $W, $rowH)); entry = $e; msg = $msg; msgH = $h })
        $y += $rowH
    }
    $more = @($Entries).Count - $shown.Count
    if ($more -gt 0) { $items.Add(@{ type = 'more'; rect = (New-Object System.Drawing.Rectangle($pad, $y + (P 2), ($W - 2 * $pad), (P 18))); text = ("$($loc.ui.more)" -replace '\{n\}', $more) }); $y += P 22 }
    $y += P 8
    $items.Add(@{ type = 'button'; rect = (New-Object System.Drawing.Rectangle($pad, $y, ($W - 2 * $pad), (P 36))); text = "$($loc.ui.stop)" })
    $y += (P 36) + (P 12)
    return @{ w = $W; h = $y; items = $items; s = $S }
}

$forms = @{}; $layouts = @{}; $signatures = @{}
function Paint-Form($form, $g) {
    $L = $layouts[$form.Tag]; if (-not $L) { return }
    $S = $L.s; $g.Clear($colBg)
    $ptFlags = $TF::NoPadding -bor $TF::SingleLine -bor $TF::EndEllipsis -bor $TF::VerticalCenter
    foreach ($it in $L.items) {
        $r = $it.rect
        switch ($it.type) {
            'header' { [System.Windows.Forms.TextRenderer]::DrawText($g, $it.text, (Get-Font 9 $false $S), $r, $colDim, $ptFlags) }
            'more' { [System.Windows.Forms.TextRenderer]::DrawText($g, $it.text, (Get-Font 9 $false $S), $r, $colDim, $ptFlags) }
            'row' {
                $e = $it.entry; $pad = [int](14 * $S)
                $pen = New-Object System.Drawing.Pen($colLine, [single][Math]::Max(1, $S)); $g.DrawLine($pen, $pad, $r.Y, $r.Right - $pad, $r.Y); $pen.Dispose()
                $bar = if ($e.kind -eq 'needs') { $colNeeds } else { $colDone }
                $br = New-Object System.Drawing.SolidBrush($bar); $g.FillRectangle($br, $pad, $r.Y + [int](8 * $S), [int](4 * $S), $r.Height - [int](14 * $S)); $br.Dispose()
                $x = $pad + [int](12 * $S); $fP = Get-Font 11 $true $S; $fA = Get-Font 9 $false $S
                $age = Get-Age ([long]$e.created)
                $ageW = [System.Windows.Forms.TextRenderer]::MeasureText($age, $fA).Width
                $top = $r.Y + [int](6 * $S)
                [System.Windows.Forms.TextRenderer]::DrawText($g, "$($e.project)", $fP, (New-Object System.Drawing.Rectangle($x, $top, ($r.Right - $pad - $x - $ageW - [int](8 * $S)), $fP.Height)), $colText, $ptFlags)
                [System.Windows.Forms.TextRenderer]::DrawText($g, $age, $fA, (New-Object System.Drawing.Rectangle(($r.Right - $pad - $ageW), $top, $ageW, $fP.Height)), $colDim, ($ptFlags -bor $TF::Right))
                [System.Windows.Forms.TextRenderer]::DrawText($g, $it.msg, (Get-Font 10 $false $S), (New-Object System.Drawing.Rectangle($x, ($top + $fP.Height + [int](2 * $S)), ($r.Right - $pad - $x), $it.msgH)), $colText, ($TF::WordBreak -bor $TF::NoPadding -bor $TF::EndEllipsis))
            }
            'button' {
                $br = New-Object System.Drawing.SolidBrush($colBtn); $g.FillRectangle($br, $r); $br.Dispose()
                [System.Windows.Forms.TextRenderer]::DrawText($g, $it.text, (Get-Font 11 $true $S), $r, [System.Drawing.Color]::White, ($TF::HorizontalCenter -bor $TF::VerticalCenter -bor $TF::SingleLine -bor $TF::EndEllipsis))
            }
        }
    }
}

function Remove-Entry($e) {
    $f = Join-Path $alertsDir "$($e.part)-$(($e.id -replace '[^A-Za-z0-9_.-]', '_')).json"
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
}
function On-Click($form, [System.Drawing.Point]$pt) {
    $L = $layouts[$form.Tag]; if (-not $L) { return }
    foreach ($it in $L.items) {
        if (-not $it.rect.Contains($pt)) { continue }
        if ($it.type -eq 'button') {
            foreach ($e in @($script:entries | Where-Object { $_.part -eq $form.Tag })) { Remove-Entry $e }
            Stop-Audio; Write-CvaLog 'hub' "stop button: $($form.Tag) cleared"
        }
        elseif ($it.type -eq 'row') {
            $e = $it.entry; Remove-Entry $e; Stop-Audio
            Write-CvaLog 'hub' "row clicked: $($e.part) [$($e.project)]"
            if ($e.part -eq 'cowork') { Open-CoworkConversation "$(if ($e.title) { $e.title } else { $e.project })" }
            else { $h = Get-CodeWindow $e; if ($h -ne [IntPtr]::Zero) { [CvaNative]::Activate($h) } }
        }
        $script:dirty = $true
        return
    }
}
function Get-Form([string]$Part) {
    if ($forms.ContainsKey($Part) -and -not $forms[$Part].IsDisposed) { return $forms[$Part] }
    $f = New-Object CvaForm
    $f.Tag = $Part; $f.Text = $titles[$Part]; $f.AutoScaleMode = 'None'; $f.FormBorderStyle = 'None'
    $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'; $f.BackColor = $colBg; $f.TopMost = $true
    $f.Cursor = [System.Windows.Forms.Cursors]::Hand
    $f.Add_Paint({ param($s, $ev) Paint-Form $s $ev.Graphics })
    $f.Add_MouseClick({ param($s, $ev) On-Click $s $ev.Location })
    $f.Add_HandleCreated({ param($s, $ev)
        $v = 2; [void][CvaNative]::DwmSetWindowAttribute($s.Handle, 33, [ref]$v, 4)
        $c = 0x00553A2A; [void][CvaNative]::DwmSetWindowAttribute($s.Handle, 34, [ref]$c, 4) })
    $forms[$Part] = $f
    return $f
}

# ---------------------------------------------------------------- main loop
$script:entries = @()
$script:dirty = $true
$readCache = @{}
$emptySince = $null
function Read-Entries {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($fi in (Get-ChildItem -LiteralPath $alertsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $k = "$($fi.Name)|$($fi.LastWriteTimeUtc.Ticks)"
        if (-not $readCache.ContainsKey($k)) { $o = Read-CvaJson $fi.FullName; if (-not $o) { continue }; $readCache[$k] = $o }
        $list.Add($readCache[$k])
    }
    if ($readCache.Count -gt 200) { $readCache.Clear() }
    return @($list | Sort-Object { [long]$_.created } -Descending)
}

function Tick {
    $now = Get-Date
    $nowMs = Get-CvaUnixMs
    $list = Read-Entries
    $limitMs = [long]$cfg.voice_limit_seconds * 1000
    if (-not $cfg.keep_window_after_timeout) {
        foreach ($e in $list) { if ($nowMs - [long]$e.created -gt $limitMs) { Remove-Entry $e } }
        $list = @($list | Where-Object { $nowMs - [long]$_.created -le $limitMs })
    }
    $sig = ($list | ForEach-Object { "$($_.part)$($_.id)$($_.kind)$($_.created)" }) -join ';'
    $minuteMark = [int]($nowMs / 30000)
    if ($sig -ne $script:lastSig -or $minuteMark -ne $script:lastMark -or $script:dirty) {
        $script:lastSig = $sig; $script:lastMark = $minuteMark; $script:dirty = $false
        $script:entries = $list
        foreach ($p in $parts) {
            $pe = @($list | Where-Object { $_.part -eq $p })
            if ($pe.Count -eq 0) { if ($forms.ContainsKey($p) -and $forms[$p].Visible) { $forms[$p].Hide() }; continue }
            $scr = Get-TargetScreen $p $pe[0]
            $S = Get-ScreenScale $scr
            $L = Build-Layout $p $pe $S
            $layouts[$p] = $L
            $wa = $scr.WorkingArea; $m = [int][Math]::Round([int]$cfg.margin_px * $S)
            $corner = "$($cfg.$p.corner)"
            $x = if ($corner -like '*right') { $wa.Right - $L.w - $m } else { $wa.Left + $m }
            $y = if ($corner -like 'top*') { $wa.Top + $m } else { $wa.Bottom - $L.h - $m }
            $f = Get-Form $p
            $f.Bounds = New-Object System.Drawing.Rectangle($x, $y, $L.w, $L.h)
            if (-not $f.Visible) { $f.Show() }
            $f.Bounds = New-Object System.Drawing.Rectangle($x, $y, $L.w, $L.h)
            $f.Invalidate()
        }
    }

    # voice: one sound at a time, parts alternate, each part repeats after its pause, until its limit
    if ($now -ge $voice.playingUntil) {
        $best = $null
        foreach ($p in $parts) {
            $pe = @($list | Where-Object { $_.part -eq $p -and -not $_.silent }); if ($pe.Count -eq 0) { continue }
            $newest = $pe[0]; $newestTime = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$newest.created).LocalDateTime
            if ($nowMs - [long]$newest.created -ge $limitMs) {
                if ($voice.limitLogged[$p] -ne $newest.created) { $voice.limitLogged[$p] = $newest.created; Write-CvaLog 'hub' "voice limit reached for $p ($([int]($limitMs / 1000)) s): silent, window stays until clicked" }
                continue
            }
            $due = ($voice.lastEnd[$p] -lt $newestTime) -or (($now - $voice.lastEnd[$p]).TotalSeconds -ge [double]$cfg.repeat_pause_seconds)
            if ($due -and (-not $best -or $voice.lastEnd[$p] -lt $voice.lastEnd[$best.part])) { $best = @{ part = $p; kind = $newest.kind } }
        }
        if ($best) {
            $a = $audio["$($best.part)-$($best.kind)"]
            if ($a) {
                Play-Audio $a; $voice.playingUntil = $now.AddMilliseconds($a.ms + 250); $voice.lastEnd[$best.part] = $voice.playingUntil
                if ($cfg.log_voice) { Write-CvaLog 'hub' "play $($best.part)-$($best.kind) at $($now.ToString('HH:mm:ss.fff')) for $($a.ms) ms" }
            }
            else { $voice.lastEnd[$best.part] = $now; Write-CvaLog 'hub' "missing audio $($best.part)-$($best.kind)" }
        }
    }

    if ($list.Count -eq 0) {
        if (-not $emptySince) { $script:emptySince = $now }
        elseif (($now - $script:emptySince).TotalSeconds -gt 2) { Try-Exit }
    }
    else { $script:emptySince = $null }
}

function Try-Exit {
    # release first, then look again: a hook that wrote an alert during our exit would otherwise be ignored
    $script:mutex.ReleaseMutex(); $script:mutex.Dispose()
    if (@(Get-ChildItem -LiteralPath $alertsDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0) {
        $c = $false; $script:mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$c)
        if ($c) { $script:emptySince = $null; return }
    }
    $script:exiting = $true
    [System.Windows.Forms.Application]::ExitThread()
}

Write-CvaLog 'hub' "start pid=$PID language=$($cfg.language)"
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({ try { Tick } catch { Write-CvaLog 'hub' "error: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)" } })
$timer.Start()
[System.Windows.Forms.Application]::Run()
$timer.Stop(); Stop-Audio
foreach ($f in $forms.Values) { try { $f.Close(); $f.Dispose() } catch { } }
Write-CvaLog 'hub' 'exit (no alerts)'
}
catch { Write-CvaLog 'hub' "fatal: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)" }
finally { if (-not $script:exiting) { try { $script:mutex.ReleaseMutex() } catch { } } }
