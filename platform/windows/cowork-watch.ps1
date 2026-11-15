# Cowork watcher: reads the conversation list of the Claude desktop app through UI Automation and raises
# Cowork alerts on state transitions (see cowork-logic.ps1). One instance per user session (mutex).
# Rows are parsed by structure (Read-CoworkRow in cowork-logic.ps1, one layout per app version: 4.x, 5.1231, 5.11492).
# Status labels come from cowork-labels.json (all languages of the Claude app).
param([int]$StepMs = 500, [int]$FastReadMs = 1500, [int]$SlowReadMs = 5000, [int]$RestartMb = 300, [switch]$Probe)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'cowork-logic.ps1')


# native UIA client (cowork-uia.cs): the managed System.Windows.Automation client leaks memory on every read (B-03)
if (-not ('CvaUia.Reader' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'cowork-uia.cs') }
if (-not ('CvaWatchNative' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices;
public static class CvaWatchNative {
    [StructLayout(LayoutKind.Sequential)] struct LII { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII p);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern uint GetTickCount();
    public static uint ForegroundPid() { uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p; }
    public static uint LastInputTick() { LII l = new LII(); l.cbSize = 8; GetLastInputInfo(ref l); return l.dwTime; }
    public static uint Tick() { return GetTickCount(); }
}
'@
}

$cfg = Get-CvaConfig
$state = Get-CvaStateDir $cfg

# label to category, from every language of the Claude app
$labels = Read-CvaJson (Join-Path $PSScriptRoot 'cowork-labels.json')
$lm = Get-CoworkLabelMaps $labels
$catOf = $lm.catOf; $langOf = $lm.langOf; $markRead = $lm.markRead

$script:listWin = [IntPtr]::Zero; $script:claudePids = @{}; $script:appLang = ''

function Get-ClaudeWindow {
    $script:claudePids = @{}; $w = [IntPtr]::Zero
    foreach ($p in Get-Process claude -ErrorAction SilentlyContinue) {
        $path = "$($p.Path)"
        if ($path -and $path -notlike '*\WindowsApps\Claude_*' -and $path -notlike '*\AnthropicClaude\*' -and $path -notlike '*\Programs\Claude\*') { continue }
        $script:claudePids[[uint32]$p.Id] = 1
        if ($w -eq [IntPtr]::Zero -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $w = $p.MainWindowHandle }
    }
    return $w
}

# One row button gives @{ title; cat; scheduled } or $null
function Read-Row($b) {
    $r = Read-CoworkRow $b $catOf $markRead
    if ($r -and -not $script:appLang -and $r.label -and $langOf.ContainsKey($r.label)) { $script:appLang = $langOf[$r.label] }
    return $r
}

# walks the copied subtree of the list; row buttons are nested inside unnamed wrapper groups
function Collect-Rows($el, $rows, [int]$depth) {
    foreach ($k in @($el.CachedChildren)) {
        $t = Get-CoworkType $k
        if ($t -eq 'Button') {
            $r = Read-Row $k
            if ($r) { if (-not $r.scheduled) { $rows.Add($r) }; continue }
        }
        # section headers ('Pinned') and the rename button of the open conversation sit under a Text: never rows
        if ($t -eq 'Text') { continue }
        if ($depth -lt 8) { Collect-Rows $k $rows ($depth + 1) }
    }
}

# Finds the conversation list (at start and after the app reloads): the first row button of the window, then
# its lowest ancestor holding the most rows (Claude 5.x wraps every row in its own groups). $true when found.
function Find-Sidebar($win) {
    $buttons = [CvaUia.Reader]::FindButtons($win)
    for ($i = 0; $i -lt $buttons.Count; $i++) {
        if (-not (Read-Row $buttons[$i])) { continue }
        if ([CvaUia.Reader]::ParentIsText($i)) { continue }
        $anc = [CvaUia.Reader]::Ancestors($i, 8)
        $best = -1; $bestN = 0
        for ($j = 0; $j -lt $anc.Count; $j++) {
            $rows = New-Object System.Collections.Generic.List[object]; Collect-Rows $anc[$j] $rows 0
            if ($rows.Count -gt $bestN) { $best = $j; $bestN = $rows.Count }
        }
        [CvaUia.Reader]::Select($best)
        return [CvaUia.Reader]::HasList
    }
    [CvaUia.Reader]::Reset()
    return $false
}

# list of rows, or $null when the list cannot be read right now
function Read-Rows {
    $win = Get-ClaudeWindow
    if ($win -eq [IntPtr]::Zero) { [CvaUia.Reader]::Reset(); return $null }
    if ($win -ne $script:listWin) { [CvaUia.Reader]::Reset(); $script:listWin = $win }
    for ($try = 0; $try -lt 2; $try++) {
        if (-not [CvaUia.Reader]::HasList) {
            # the app sometimes rejects UIA calls for a few seconds (E_UNEXPECTED while it reloads): treat as "not readable"
            $ok = $false
            try { $ok = Find-Sidebar $win } catch { [CvaUia.Reader]::Reset() }
            if (-not $ok) { return $null }
        }
        $tree = [CvaUia.Reader]::Read()
        if ($null -eq $tree) { continue }
        $rows = New-Object System.Collections.Generic.List[object]
        Collect-Rows $tree $rows 0
        if ($rows.Count -gt 0) { return $rows.ToArray() }
        [CvaUia.Reader]::Reset()
    }
    return $null
}

# alerts raised by this watcher: key to @{ title; kind; tick }
$alerts = @{}
$runningSince = @{}
function Set-Alert([string]$Title, [string]$Kind, [int]$Count) {
    for ($i = 1; $i -le [Math]::Max(1, [Math]::Min($Count, 5)); $i++) {
        $key = if ($i -eq 1) { $Title } else { "$Title ($i)" }
        if ($i -gt 1 -and $alerts.ContainsKey($key)) { continue }
        $id = Get-CvaHash $key
        $alerts[$key] = @{ title = $Title; kind = $Kind; tick = [CvaWatchNative]::Tick(); id = $id }
        Add-CvaAlert $cfg 'cowork' $id $Kind $key @{ title = $Title }
    }
}
function Clear-Alerts([string]$Title, [string]$Kind, [string]$Why) {
    foreach ($k in @($alerts.Keys)) {
        $a = $alerts[$k]
        if ($a.title -eq $Title -and (-not $Kind -or $a.kind -eq $Kind)) {
            [void](Remove-CvaAlert $cfg 'cowork' $a.id); $alerts.Remove($k); Write-CvaLog 'cowork' "alert removed [$k]: $Why"
        }
    }
}

if ($Probe) {
    # used by doctor.ps1 and install.ps1: print what the watcher sees, then exit
    $rows = Read-Rows
    # size of what one read covers (elements in the cached sidebar subtree), to keep the read small
    $size = 0
    $tree = [CvaUia.Reader]::Read()
    if ($tree) {
        $st = New-Object System.Collections.Stack; $st.Push($tree)
        while ($st.Count) { $e = $st.Pop(); $size++; foreach ($k in @($e.CachedChildren)) { $st.Push($k) } }
    }
    [PSCustomObject]@{ window = ((Get-ClaudeWindow) -ne [IntPtr]::Zero); rows = @($rows); language = $script:appLang; read_elements = $size } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}
# Restart safety net: above RestartMb of private memory the watcher hands its state to a new instance and exits.
# Handover file: the confirmed snapshot and the running start times, valid for 60 s (a restart takes 1-3 s).
$handover = Join-Path $state 'cowork-handover.json'
function ConvertTo-Snap($o) {
    if ($null -eq $o) { return $null }
    $s = @{}; foreach ($p in $o.PSObject.Properties) { $s[$p.Name] = @{ active = [int]$p.Value.active; needs = [int]$p.Value.needs; unread = [int]$p.Value.unread; other = [int]$p.Value.other } }
    return $s
}
function Start-Successor {
    $exe = Join-Path $PSScriptRoot 'launch-hidden.exe'
    if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe -ArgumentList 'cowork-watch.ps1' -WorkingDirectory $PSScriptRoot }
    else { Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" -WindowStyle Hidden }
}

$mx = New-Object System.Threading.Mutex($false, 'Local\ClaudeVoiceAlertsCowork')
if (-not $mx.WaitOne(0)) { exit 0 }
Write-CvaLog 'cowork' "watcher start pid=$PID"
# prev = confirmed snapshot (what transitions are computed on), rawPrev = what the last read saw
$prev = $null; $rawPrev = $null; $unavailableLogged = $false
$nextRead = [long][CvaWatchNative]::Tick(); $lastDone = @{}; $nextMemCheck = [CvaWatchNative]::Tick() + 60000L

# alerts still on screen from an earlier instance (restart, crash): taken over, so the dismiss rule closes them
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $state 'alerts') -Filter 'cowork-*.json' -ErrorAction SilentlyContinue)) {
    $a = Read-CvaJson $f.FullName
    if ($a -and $a.id -and $a.project) { $alerts["$($a.project)"] = @{ title = "$(if ($a.title) { $a.title } else { $a.project })"; kind = "$($a.kind)"; tick = [CvaWatchNative]::Tick(); id = "$($a.id)" } }
}
if (Test-Path -LiteralPath $handover) {
    $h = Read-CvaJson $handover
    Remove-Item -LiteralPath $handover -Force -ErrorAction SilentlyContinue
    if ($h -and ((Get-CvaUnixMs) - [long]$h.written) -lt 60000) {
        $prev = ConvertTo-Snap $h.prev; $rawPrev = ConvertTo-Snap $h.rawPrev
        if ($h.runningSince) { foreach ($p in $h.runningSince.PSObject.Properties) { $runningSince[$p.Name] = [datetime]::Parse($p.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } }
        Write-CvaLog 'cowork' "resumed after restart: $(@($prev.Keys).Count) conversations, $($alerts.Count) alerts on screen"
    }
}
while ($true) {
    try {
        if (@($cfg.parts) -notcontains 'cowork') { Start-Sleep -Seconds 5; $cfg = Get-CvaConfig; continue }
        $fgClaude = $script:claudePids.ContainsKey([CvaWatchNative]::ForegroundPid())
        $lastInput = [CvaWatchNative]::LastInputTick()

        # alerts removed elsewhere (click on the row, hotkey) are forgotten
        foreach ($k in @($alerts.Keys)) { if (-not (Test-Path -LiteralPath (Join-Path $state "alerts\cowork-$($alerts[$k].id).json"))) { $alerts.Remove($k) } }
        # dismiss rule: Claude in front and keyboard/mouse used after the alert
        foreach ($k in @($alerts.Keys)) {
            if (Test-CoworkShouldDismiss $fgClaude $lastInput $alerts[$k].tick) { Clear-Alerts $alerts[$k].title $null 'Claude in front and used' }
        }

        $now = [long][CvaWatchNative]::Tick()
        if (((($now - $nextRead) % 4294967296L + 4294967296L) % 4294967296L) -lt 2147483648L) {
            # next read planned first, so a read that throws is retried at the slow pace, not every step
            $nextRead = ($now + $SlowReadMs) % 4294967296L
            $rows = Read-Rows
            $interval = $SlowReadMs
            if ($null -eq $rows) {
                # keep the last good state: a short read failure must not lose transitions
                if (-not $unavailableLogged -and $null -ne $prev) { Write-CvaLog 'cowork' 'conversation list not readable (app closed, in tray or other view); keeping last state'; $unavailableLogged = $true }
            }
            else {
                $unavailableLogged = $false
                $raw = New-CoworkSnapshot $rows
                $interval = Get-CoworkReadInterval $raw $FastReadMs $SlowReadMs
                if ($null -eq $prev) { $cur = $raw; Write-CvaLog 'cowork' "baseline: $($rows.Count) conversations, app language $script:appLang (old signals ignored)" }
                else {
                    $cur = Get-CoworkStable $prev $rawPrev $raw
                    $r = Get-CoworkEvents $prev $cur
                    if ($r.rebaseline) { Write-CvaLog 'cowork' 'view changed (many conversations appeared/disappeared): new baseline' }
                    else { foreach ($tr in (Get-CoworkTransitions $rawPrev $raw)) { Write-CvaLog 'cowork' "row $tr" } }
                    $idleMs = (([long][CvaWatchNative]::Tick() - [long]$lastInput) % 4294967296L + 4294967296L) % 4294967296L
                    foreach ($e in $r.events) {
                        $t = $e.title
                        switch ($e.type) {
                            'rename' { if ($runningSince.ContainsKey($e.from)) { $runningSince[$t] = $runningSince[$e.from]; $runningSince.Remove($e.from) } }
                            'started' { if (-not $runningSince.ContainsKey($t)) { $runningSince[$t] = Get-Date } }
                            'clear_needs' { Clear-Alerts $t 'needs' 'no longer waiting' }
                            'clear_done' { Clear-Alerts $t 'done' 'read or restarted' }
                            { $_ -in 'needs', 'done' } {
                                $kind = $e.type
                                if ($kind -eq 'done') {
                                    if (Test-CoworkDebounced $lastDone[$t] ([long][CvaWatchNative]::Tick())) {
                                        Write-CvaLog 'cowork' "skip done [$t]: another done less than 10 s ago"; break
                                    }
                                    $lastDone[$t] = [long][CvaWatchNative]::Tick()
                                    $min = [int]$cfg.min_task_seconds
                                    if ($min -gt 0 -and $runningSince.ContainsKey($t) -and ((Get-Date) - $runningSince[$t]).TotalSeconds -lt $min) {
                                        Write-CvaLog 'cowork' "skip done [$t]: shorter than min_task_seconds $min"; $runningSince.Remove($t); break
                                    }
                                    $runningSince.Remove($t)
                                }
                                if (Test-CoworkShouldAlert $fgClaude $idleMs ([int]$cfg.cowork_idle_seconds)) {
                                    Clear-Alerts $t $null 'replaced'
                                    Set-Alert $t $kind $e.count
                                    Write-CvaLog 'cowork' "ALERT $kind [$t] (Claude in front: $fgClaude, idle $([int]($idleMs / 1000)) s)"
                                }
                                else { Write-CvaLog 'cowork' "skip $kind [$t]: Claude in front and used $([int]($idleMs / 1000)) s ago" }
                            }
                        }
                    }
                }
                $prev = $cur; $rawPrev = $raw
            }
            $nextRead = ([long][CvaWatchNative]::Tick() + $interval) % 4294967296L
        }
        # restart safety net, checked once a minute
        $now = [long][CvaWatchNative]::Tick()
        if (((($now - $nextMemCheck) % 4294967296L + 4294967296L) % 4294967296L) -lt 2147483648L) {
            $nextMemCheck = ($now + 60000L) % 4294967296L
            $mb = [int]([System.Diagnostics.Process]::GetCurrentProcess().PrivateMemorySize64 / 1MB)
            if ($RestartMb -gt 0 -and $mb -gt $RestartMb -and $null -ne $prev) {
                $rs = @{}; foreach ($k in $runningSince.Keys) { $rs[$k] = $runningSince[$k].ToString('o') }
                Write-CvaJson $handover ([PSCustomObject]@{ written = (Get-CvaUnixMs); prev = $prev; rawPrev = $rawPrev; runningSince = $rs })
                Write-CvaLog 'cowork' "restart: private memory $mb MB above $RestartMb MB, handing over to a new watcher"
                $mx.ReleaseMutex(); $mx.Dispose()
                Start-Successor
                exit 0
            }
        }
    } catch { Write-CvaLog 'cowork' "error: $_" }
    Start-Sleep -Milliseconds $StepMs
}
