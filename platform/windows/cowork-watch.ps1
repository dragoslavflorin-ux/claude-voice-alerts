# Cowork watcher: reads the conversation list of the Claude desktop app through UI Automation and raises
# Cowork alerts on state transitions (see cowork-logic.ps1). One instance per user session (mutex).
# Rows are parsed by structure: [status element] [Group > Text title] [optional Text badge = scheduled task].
# Status labels come from cowork-labels.json (all languages of the Claude app).
param([int]$StepMs = 500, [int]$ReadEverySteps = 3, [switch]$Probe)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'cowork-logic.ps1')


Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
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
$A = [System.Windows.Automation.AutomationElement]

# label to category, from every language of the Claude app
$labels = Read-CvaJson (Join-Path $PSScriptRoot 'cowork-labels.json')
$catOf = @{}; $langOf = @{}; $markRead = @{}
$map = @{ 'Running' = 'active'; 'Using the browser' = 'active'; 'Awaiting input' = 'needs'; 'Awaiting answer' = 'needs'
    'Unread response' = 'unread'; 'Idle' = 'other'; 'Done' = 'other'; 'Mark as unread' = 'wrapper' }
foreach ($lp in $labels.PSObject.Properties) {
    foreach ($kp in $lp.Value.PSObject.Properties) {
        $v = "$($kp.Value)"; if (-not $v) { continue }
        if ($kp.Name -eq 'Mark as read') { $markRead[$v] = 1; $langOf[$v] = $lp.Name; continue }
        if ($map.ContainsKey($kp.Name)) { if (-not $catOf.ContainsKey($v)) { $catOf[$v] = $map[$kp.Name] }; if (-not $langOf.ContainsKey($v)) { $langOf[$v] = $lp.Name } }
    }
}

$cr = New-Object System.Windows.Automation.CacheRequest
$cr.Add($A::NameProperty); $cr.Add($A::ControlTypeProperty)
$cr.TreeScope = [System.Windows.Automation.TreeScope]'Element, Descendants'
$cr.TreeFilter = [System.Windows.Automation.Automation]::RawViewCondition
$btnCond = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$script:sidebar = $null; $script:claudePids = @{}; $script:appLang = ''

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
    $kids = @($b.CachedChildren)
    if ($kids.Count -lt 2) { return $null }
    $statusEl = $kids[0]; $title = $null; $badge = $false; $seenGroup = $false
    foreach ($k in $kids[1..($kids.Count - 1)]) {
        $ct = $k.Cached.ControlType
        if ($ct -eq [System.Windows.Automation.ControlType]::Group -and -not $seenGroup) {
            $seenGroup = $true
            foreach ($t in @($k.CachedChildren)) { if ($t.Cached.ControlType -eq [System.Windows.Automation.ControlType]::Text) { $title = $t.Cached.Name; break } }
        }
        elseif ($seenGroup -and $ct -eq [System.Windows.Automation.ControlType]::Text) { $badge = $true }
    }
    if (-not $title) { return $null }
    $n = $statusEl.Cached.Name; $unread = $false; $label = $n
    if ($markRead.ContainsKey($n) -or $catOf[$n] -eq 'wrapper') {
        $unread = $markRead.ContainsKey($n)
        $inner = @($statusEl.CachedChildren); $label = if ($inner.Count) { $inner[0].Cached.Name } else { '' }
    }
    $cat = $catOf[$label]
    if (-not $cat -or $cat -eq 'wrapper') { if ($unread) { $cat = 'unread' } else { return $null } }
    if ($cat -eq 'other' -and $unread) { $cat = 'unread' }
    if (-not $script:appLang -and $langOf.ContainsKey($label)) { $script:appLang = $langOf[$label] }
    return @{ title = $title; cat = $cat; scheduled = $badge }
}

# walks the cached subtree of the sidebar; row buttons are nested inside unnamed wrapper groups
function Collect-Rows($el, $rows, [int]$depth) {
    foreach ($k in @($el.CachedChildren)) {
        if ($k.Cached.ControlType -eq [System.Windows.Automation.ControlType]::Button) {
            $r = Read-Row $k
            if ($r) { if (-not $r.scheduled) { $rows.Add($r) }; continue }
        }
        if ($depth -lt 8) { Collect-Rows $k $rows ($depth + 1) }
    }
}

function Find-Sidebar($win) {
    $root = $A::FromHandle($win)
    $c2 = New-Object System.Windows.Automation.CacheRequest
    $c2.Add($A::NameProperty); $c2.Add($A::ControlTypeProperty)
    $c2.TreeScope = [System.Windows.Automation.TreeScope]'Element, Descendants'
    $c2.TreeFilter = [System.Windows.Automation.Automation]::RawViewCondition
    $act = $c2.Activate()
    try {
        foreach ($b in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)) {
            if (Read-Row $b) { return [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($b) }
        }
    } finally { $act.Dispose() }
    return $null
}

# list of rows, or $null when the list cannot be read right now
function Read-Rows {
    $win = Get-ClaudeWindow
    if ($win -eq [IntPtr]::Zero) { $script:sidebar = $null; return $null }
    for ($try = 0; $try -lt 2; $try++) {
        if (-not $script:sidebar) { $script:sidebar = Find-Sidebar $win; if (-not $script:sidebar) { return $null } }
        try {
            $c = $script:sidebar.GetUpdatedCache($cr)
            $rows = New-Object System.Collections.Generic.List[object]
            Collect-Rows $c $rows 0
            if ($rows.Count -gt 0) { return $rows.ToArray() }
            $script:sidebar = $null
        } catch { $script:sidebar = $null }
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
    [PSCustomObject]@{ window = ((Get-ClaudeWindow) -ne [IntPtr]::Zero); rows = @($rows); language = $script:appLang } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}
$mx = New-Object System.Threading.Mutex($false, 'Local\ClaudeVoiceAlertsCowork')
if (-not $mx.WaitOne(0)) { exit 0 }
Write-CvaLog 'cowork' "watcher start pid=$PID"
$prev = $null; $i = 0; $unavailableLogged = $false
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

        if ($i % $ReadEverySteps -eq 0) {
            $rows = Read-Rows
            if ($null -eq $rows) {
                # keep the last good state: a short read failure must not lose transitions
                if (-not $unavailableLogged -and $null -ne $prev) { Write-CvaLog 'cowork' 'conversation list not readable (app closed, in tray or other view); keeping last state'; $unavailableLogged = $true }
            }
            else {
                $unavailableLogged = $false
                $cur = New-CoworkSnapshot $rows
                if ($null -eq $prev) { Write-CvaLog 'cowork' "baseline: $($rows.Count) conversations, app language $script:appLang (old signals ignored)" }
                else {
                    $r = Get-CoworkEvents $prev $cur
                    if ($r.rebaseline) { Write-CvaLog 'cowork' 'view changed (many conversations appeared/disappeared): new baseline' }
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
                $prev = $cur
            }
        }
    } catch { Write-CvaLog 'cowork' "error: $_" }
    $i++
    Start-Sleep -Milliseconds $StepMs
}
