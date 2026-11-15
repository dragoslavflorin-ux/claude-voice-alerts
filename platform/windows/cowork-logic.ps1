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

# G-18: the app shows "Running" for under a second after a conversation is opened, without a new task. A row
# counts as running only when two consecutive reads see it running: on the first read its running count stays
# as confirmed before. Returns the snapshot to feed to Get-CoworkEvents.
function Get-CoworkStable($Confirmed, $RawPrev, $RawCur) {
    $s = @{}
    foreach ($t in $RawCur.Keys) {
        $ca = Get-CoworkCount $RawCur $t 'active'
        if ($Confirmed.ContainsKey($t) -and $ca -gt (Get-CoworkCount $Confirmed $t 'active') -and $ca -gt (Get-CoworkCount $RawPrev $t 'active')) {
            $s[$t] = $Confirmed[$t]; continue   # seen running once: wait for the next read
        }
        $s[$t] = $RawCur[$t]
    }
    return $s
}

# State of one title as text for the log: 'active', 'other', 'unread+other' (several rows), 'gone'
function Get-CoworkStateText($Snap, [string]$Title) {
    if (-not $Snap.ContainsKey($Title)) { return 'gone' }
    $p = @(foreach ($c in 'active', 'needs', 'unread', 'other') { $n = [int]$Snap[$Title][$c]; if ($n -eq 1) { $c } elseif ($n -gt 1) { "$c x$n" } })
    return ($p -join '+')
}

# Every row whose state changed between two reads: @( "title: from -> to" )
function Get-CoworkTransitions($Prev, $Cur) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($t in @(@($Prev.Keys) + @($Cur.Keys) | Sort-Object -Unique)) {
        $a = Get-CoworkStateText $Prev $t; $b = Get-CoworkStateText $Cur $t
        if ($a -ne $b) { $out.Add("[$t] $a -> $b") }
    }
    return $out.ToArray()
}

# Adaptive reading: fast while a conversation runs or waits (and right after one is first seen running), slow otherwise
function Get-CoworkReadInterval($RawCur, [int]$FastMs = 1500, [int]$SlowMs = 5000) {
    foreach ($t in $RawCur.Keys) { if ((Get-CoworkCount $RawCur $t 'active') + (Get-CoworkCount $RawCur $t 'needs') -gt 0) { return $FastMs } }
    return $SlowMs
}

# Debounce: true when a "done" for the same title was handled less than Ms ago (ticks from GetTickCount, wrap safe)
function Test-CoworkDebounced($LastTick, [long]$NowTick, [int]$Ms = 10000) {
    if ($null -eq $LastTick) { return $false }
    $d = (($NowTick - [long]$LastTick) % 4294967296L + 4294967296L) % 4294967296L
    return ($d -lt $Ms)
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

# Label maps from cowork-labels.json (every language of the Claude app): label to category, label to language,
# and the "Mark as read" names (a row wrapped in "Mark as read" is unread).
function Get-CoworkLabelMaps($Labels) {
    $catOf = @{}; $langOf = @{}; $markRead = @{}
    $map = @{ 'Running' = 'active'; 'Using the browser' = 'active'; 'Awaiting input' = 'needs'; 'Awaiting answer' = 'needs'
        'Unread response' = 'unread'; 'Idle' = 'other'; 'Done' = 'other'; 'Mark as unread' = 'wrapper' }
    foreach ($lp in $Labels.PSObject.Properties) {
        foreach ($kp in $lp.Value.PSObject.Properties) {
            $v = "$($kp.Value)"; if (-not $v) { continue }
            if ($kp.Name -eq 'Mark as read') { $markRead[$v] = 1; $langOf[$v] = $lp.Name; continue }
            if ($map.ContainsKey($kp.Name)) { if (-not $catOf.ContainsKey($v)) { $catOf[$v] = $map[$kp.Name] }; if (-not $langOf.ContainsKey($v)) { $langOf[$v] = $lp.Name } }
        }
    }
    return @{ catOf = $catOf; langOf = $langOf; markRead = $markRead }
}

# Control type of a cached element without the UIA assembly: 'Group', 'Text', 'Button', 'StatusBar', ...
function Get-CoworkType($El) { return ("$($El.Cached.ControlType.ProgrammaticName)" -replace '^ControlType\.', '') }
function Test-CoworkNamed($El, [int]$Depth) {
    if ("$($El.Cached.Name)") { return $true }
    if ($Depth -ge 3) { return $false }
    foreach ($k in @($El.CachedChildren)) { if (Test-CoworkNamed $k ($Depth + 1)) { return $true } }
    return $false
}

# One conversation row (the row button) gives @{ title; cat; scheduled; label } or $null when it is not a row
# or its state cannot be told. Layouts seen in the Claude app:
#   4.23118  Button > [status element] [Group > Text title] [Text badge]
#   5.1231   Button > [Group > Text title] [Button 'Mark as unread' > Image 'Done'] or [Image 'Idle']
#   5.11492  Button > [Group > Text title, Text badge, StatusBar 'Running' / 'Awaiting input' / 'Unread response'];
#            an idle row has no status element at all
# The title is the first Text of the first Group that holds a Text; a further Text is a badge (scheduled task,
# artifact); every other element is a status element.
function Read-CoworkRow($Button, [hashtable]$CatOf, [hashtable]$MarkRead) {
    $kids = @($Button.CachedChildren)
    $gi = -1
    for ($i = 0; $i -lt $kids.Count; $i++) {
        if ((Get-CoworkType $kids[$i]) -ne 'Group') { continue }
        if (@($kids[$i].CachedChildren | Where-Object { (Get-CoworkType $_) -eq 'Text' }).Count) { $gi = $i; break }
    }
    if ($gi -lt 0) { return $null }
    $title = $null; $badge = $false
    $statusEls = New-Object System.Collections.Generic.List[object]
    foreach ($k in @($kids[$gi].CachedChildren)) {
        if ((Get-CoworkType $k) -eq 'Text') { if ($null -eq $title) { $title = "$($k.Cached.Name)" } else { $badge = $true } }
        else { $statusEls.Add($k) }
    }
    if (-not $title) { return $null }
    for ($i = 0; $i -lt $kids.Count; $i++) {
        if ($i -eq $gi) { continue }
        if ($i -gt $gi -and (Get-CoworkType $kids[$i]) -eq 'Text') { $badge = $true } else { $statusEls.Add($kids[$i]) }
    }
    # unnamed decoration (no name anywhere in its subtree) is not a status element; StatusBar and Image always are
    $statusEls = @($statusEls | Where-Object { (Get-CoworkType $_) -in 'StatusBar', 'Image' -or (Test-CoworkNamed $_ 0) })
    $label = ''; $wrapper = ''
    foreach ($el in $statusEls) {
        $st = Get-CoworkRowLabel $el $CatOf $MarkRead
        if ($st.wrapper -and -not $wrapper) { $wrapper = $st.wrapper }
        if ($st.label -and -not $label) { $label = $st.label }
    }
    $unread = $MarkRead.ContainsKey($wrapper)
    if ($label) { $cat = $CatOf[$label] } else { $cat = $null }
    if (-not $cat -or $cat -eq 'wrapper') {
        if ($unread) { $cat = 'unread' }
        elseif (-not $wrapper -and $statusEls.Count -eq 0) { $cat = 'other' }   # 5.11492: no status element = idle
        else { return $null }                                                  # a status element we cannot read
    }
    if ($cat -eq 'other' -and $unread) { $cat = 'unread' }
    return @{ title = $title; cat = $cat; scheduled = $badge; label = $label }
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
