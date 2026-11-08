# Pure transition logic for the Cowork watcher. No UI, no I/O: testable with sequences of states.
# A snapshot is a hashtable: title to hashtable(category to count), categories: active, needs, unread, other.
#   active = Running / Using the browser, needs = Awaiting input / Awaiting answer,
#   unread = finished and not read yet, other = idle / done and read.
# Counting per title handles several conversations with the same title.

function New-CoworkSnapshot($Rows) {
    $s = @{}
    foreach ($r in $Rows) {
        if (-not $s.ContainsKey($r.title)) { $s[$r.title] = @{ active = 0; needs = 0; unread = 0; other = 0 } }
        $s[$r.title][$r.cat]++
    }
    return $s
}

function Get-CoworkCount($Snap, [string]$Title, [string]$Cat) {
    if ($Snap.ContainsKey($Title)) { return [int]$Snap[$Title][$Cat] } else { return 0 }
}

function Get-CoworkTotal($Snap, [string]$Title) {
    if (-not $Snap.ContainsKey($Title)) { return 0 }
    $h = $Snap[$Title]; return ([int]$h.active + [int]$h.needs + [int]$h.unread + [int]$h.other)
}

# Returns @{ events = @( @{ type; title; count; from } ); rebaseline = bool }
#   needs       a conversation started waiting for permission or an answer
#   done        a conversation left Running/Awaiting, or became unread
#   clear_needs the wait ended elsewhere (approved, answered, phone, web)
#   clear_done  the result was read, or the conversation restarted
#   started     a conversation started running (used for min_task_seconds)
#   rename      a running conversation got its final title (from = old title)
function Get-CoworkEvents($Prev, $Cur, [int]$MassChange = 4) {
    $ev = New-Object System.Collections.Generic.List[object]
    $gone = @($Prev.Keys | Where-Object { -not $Cur.ContainsKey($_) })
    $new = @($Cur.Keys | Where-Object { -not $Prev.ContainsKey($_) })
    if (($gone.Count + $new.Count) -gt $MassChange) { return @{ events = @(); rebaseline = $true } }

    # rename: exactly one title disappeared and exactly one appeared (titles are generated after the first reply)
    $alias = @{}
    if ($gone.Count -eq 1 -and $new.Count -eq 1 -and (Get-CoworkTotal $Prev $gone[0]) -eq 1 -and (Get-CoworkTotal $Cur $new[0]) -eq 1) {
        $alias[$new[0]] = $gone[0]
        $ev.Add(@{ type = 'rename'; title = $new[0]; from = $gone[0]; count = 1 })
    }
    $activeGone = $false
    foreach ($g in $gone) {
        if ($alias.Values -contains $g) { continue }
        if ((Get-CoworkCount $Prev $g 'active') + (Get-CoworkCount $Prev $g 'needs') -gt 0) { $activeGone = $true }
        if ((Get-CoworkCount $Prev $g 'needs') -gt 0) { $ev.Add(@{ type = 'clear_needs'; title = $g; count = 99 }) }
        if ((Get-CoworkCount $Prev $g 'unread') -gt 0) { $ev.Add(@{ type = 'clear_done'; title = $g; count = 99 }) }
    }

    foreach ($t in $Cur.Keys) {
        $pt = if ($alias.ContainsKey($t)) { $alias[$t] } else { $t }
        $known = $Prev.ContainsKey($pt)
        $pa = Get-CoworkCount $Prev $pt 'active'; $pn = Get-CoworkCount $Prev $pt 'needs'; $pu = Get-CoworkCount $Prev $pt 'unread'
        $ca = Get-CoworkCount $Cur $t 'active'; $cn = Get-CoworkCount $Cur $t 'needs'; $cu = Get-CoworkCount $Cur $t 'unread'

        if ($ca -gt $pa -and $known) { $ev.Add(@{ type = 'started'; title = $t; count = $ca - $pa }) }
        if (-not $known -and $ca -gt 0) { $ev.Add(@{ type = 'started'; title = $t; count = $ca }) }
        if ($cn -lt $pn) { $ev.Add(@{ type = 'clear_needs'; title = $t; count = $pn - $cn }) }
        if ($cu -lt $pu) { $ev.Add(@{ type = 'clear_done'; title = $t; count = $pu - $cu }) }
        elseif ($known -and ($ca + $cn) -gt ($pa + $pn)) { $ev.Add(@{ type = 'clear_done'; title = $t; count = 99 }) }

        if ($cn -gt $pn) { $ev.Add(@{ type = 'needs'; title = $t; count = $cn - $pn }); continue }
        $busyPrev = $pa + $pn; $busyCur = $ca + $cn
        if ($known -and $busyCur -lt $busyPrev) { $ev.Add(@{ type = 'done'; title = $t; count = $busyPrev - $busyCur }); continue }
        if ($known -and $cu -gt $pu) { $ev.Add(@{ type = 'done'; title = $t; count = $cu - $pu }); continue }
        if (-not $known -and $cu -gt 0 -and $activeGone) { $ev.Add(@{ type = 'done'; title = $t; count = 1 }) }
    }
    return @{ events = $ev.ToArray(); rebaseline = $false }
}

# Status label of a conversation row, from its first child element (UIA cached element or any object with
# .Cached.Name and .CachedChildren). Older app versions name that element directly ("Running", "Idle"), or wrap the
# label in a "Mark as read" / "Mark as unread" button; newer versions wrap it in an unnamed group
# (Group > StatusBar "Running"). Returns @{ label; wrapper } where wrapper is the "Mark as ..." name or ''.
function Get-CoworkRowLabel($StatusEl, [hashtable]$Known, [hashtable]$MarkRead) {
    $n = "$($StatusEl.Cached.Name)"
    $wrapper = ''
    if ($MarkRead.ContainsKey($n) -or $Known[$n] -eq 'wrapper') { $wrapper = $n }
    elseif ($Known.ContainsKey($n)) { return @{ label = $n; wrapper = '' } }
    # search the children (a few levels) for the first known status label
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($k in @($StatusEl.CachedChildren)) { $queue.Enqueue(@($k, 1)) }
    while ($queue.Count) {
        $item = $queue.Dequeue(); $el = $item[0]; $d = $item[1]
        $kn = "$($el.Cached.Name)"
        if ($Known.ContainsKey($kn) -and $Known[$kn] -ne 'wrapper') { return @{ label = $kn; wrapper = $wrapper } }
        if ($d -lt 3) { foreach ($k in @($el.CachedChildren)) { $queue.Enqueue(@($k, $d + 1)) } }
    }
    return @{ label = ''; wrapper = $wrapper }
}

# Foreground rule: alert if Claude is not the active window, or it is but nobody touched keyboard/mouse for IdleSeconds.
function Test-CoworkShouldAlert([bool]$ClaudeForeground, [long]$IdleMs, [int]$IdleSeconds) {
    if (-not $ClaudeForeground) { return $true }
    return ($IdleMs -ge ($IdleSeconds * 1000L))
}

# Stop rule: an alert ends when Claude is in front and there was input after the alert was raised.
# Ticks are GetTickCount values (ms, uint32, wrap after 49.7 days).
function Test-CoworkShouldDismiss([bool]$ClaudeForeground, [long]$LastInputTick, [long]$AlertTick) {
    if (-not $ClaudeForeground) { return $false }
    $d = (($LastInputTick - $AlertTick) % 4294967296L + 4294967296L) % 4294967296L
    return ($d -gt 0 -and $d -lt 2147483648L)
}
