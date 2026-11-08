# Unit tests for platform\windows\cowork-logic.ps1 (pure functions, no UI).
# Run: powershell -ExecutionPolicy Bypass -File tests\test-cowork-logic.ps1
. (Join-Path $PSScriptRoot '..\platform\windows\cowork-logic.ps1')
$script:pass = 0; $script:fail = 0
function Snap([object[]]$pairs) { $rows = @(); foreach ($p in $pairs) { $rows += @{ title = $p[0]; cat = $p[1] } }; return (New-CoworkSnapshot $rows) }
function Ev($a, $b) { $r = Get-CoworkEvents $a $b; return @($r.events | Where-Object { $_.type -in 'needs', 'done', 'clear_needs', 'clear_done' } | ForEach-Object { "$($_.type):$($_.title)" }) }
function Expect([string]$name, $got, [string[]]$want) {
    $g = (@($got) | Sort-Object) -join ' '; $w = (@($want) | Sort-Object) -join ' '
    if ($g -eq $w) { $script:pass++; "PASS  $name" } else { $script:fail++; "FAIL  $name`n      got:  [$g]`n      want: [$w]" }
}

# 1. open conversation finishes: Running then Idle (it never becomes unread because it is on screen)
Expect 'open conversation finishes (Running to Idle)' (Ev (Snap @(, @('A', 'active'))) (Snap @(, @('A', 'other')))) @('done:A')
# 2. short task finished between two reads: Idle to unread, Running never seen
Expect 'short task between reads (Idle to unread)' (Ev (Snap @(, @('A', 'other'))) (Snap @(, @('A', 'unread')))) @('done:A')
# 3. identical titles: one of two "Plan" conversations finishes, the other keeps running
Expect 'identical titles, one finishes' (Ev (Snap @(@('Plan', 'active'), @('Plan', 'active'))) (Snap @(@('Plan', 'active'), @('Plan', 'unread')))) @('done:Plan')
Expect 'identical titles, nothing changes' (Ev (Snap @(@('Plan', 'active'), @('Plan', 'other'))) (Snap @(@('Plan', 'other'), @('Plan', 'active')))) @()
# 4. permission approved on another device: Awaiting to Running clears the alert, no done
Expect 'needs raised' (Ev (Snap @(, @('A', 'active'))) (Snap @(, @('A', 'needs')))) @('needs:A')
Expect 'approved elsewhere (Awaiting to Running)' (Ev (Snap @(, @('A', 'needs'))) (Snap @(, @('A', 'active')))) @('clear_needs:A')
Expect 'answered and finished (Awaiting to unread)' (Ev (Snap @(, @('A', 'needs'))) (Snap @(, @('A', 'unread')))) @('clear_needs:A', 'done:A')
# result read on the phone / web: unread to read clears the done alert
Expect 'read elsewhere (unread to other)' (Ev (Snap @(, @('A', 'unread'))) (Snap @(, @('A', 'other')))) @('clear_done:A')
Expect 'restarted (unread to Running)' (Ev (Snap @(, @('A', 'unread'))) (Snap @(, @('A', 'active')))) @('clear_done:A')
# no double alert for the same transition
Expect 'no repeat when nothing changes' (Ev (Snap @(, @('A', 'unread'))) (Snap @(, @('A', 'unread')))) @()
# new conversation: running under a temporary title, then renamed and finished
$r = Get-CoworkEvents (Snap @(, @('New chat', 'active'))) (Snap @(, @('Cat face 1+1', 'unread')))
Expect 'rename + finish in the same read' (@($r.events | Where-Object { $_.type -in 'done', 'needs' } | ForEach-Object { "$($_.type):$($_.title)" })) @('done:Cat face 1+1')
Expect 'new idle conversation is not an alert' (Ev (Snap @(, @('A', 'other'))) (Snap @(@('A', 'other'), @('B', 'other')))) @()
# view change: many conversations appear at once (other project selected) to new baseline, no alerts
$many = Snap @(@('x1', 'unread'), @('x2', 'unread'), @('x3', 'unread'), @('x4', 'unread'), @('x5', 'unread'))
$r = Get-CoworkEvents (Snap @(, @('A', 'active'))) $many
Expect 'view change gives a new baseline' (@(if ($r.rebaseline) { 'rebaseline' })) @('rebaseline')

# 5. foreground rule (cowork_idle_seconds = 20)
Expect 'Claude not in front: alert' (@(if (Test-CoworkShouldAlert $false 0 20) { 'alert' })) @('alert')
Expect 'Claude in front, no input for 60 s: alert' (@(if (Test-CoworkShouldAlert $true 60000 20) { 'alert' })) @('alert')
Expect 'Claude in front, input 5 s ago: no alert' (@(if (Test-CoworkShouldAlert $true 5000 20) { 'alert' })) @()
# dismiss rule: Claude in front and input after the alert
Expect 'dismiss: input after alert, Claude in front' (@(if (Test-CoworkShouldDismiss $true 1500 1000) { 'dismiss' })) @('dismiss')
Expect 'keep: input before alert' (@(if (Test-CoworkShouldDismiss $true 900 1000) { 'dismiss' })) @()
Expect 'keep: Claude not in front' (@(if (Test-CoworkShouldDismiss $false 1500 1000) { 'dismiss' })) @()
Expect 'dismiss across tick wrap' (@(if (Test-CoworkShouldDismiss $true 100 4294967000) { 'dismiss' })) @('dismiss')

# 6. status label of a row, on the structures seen in the Claude app (fake UIA elements)
function El([string]$name, [object[]]$kids = @()) { [PSCustomObject]@{ Cached = [PSCustomObject]@{ Name = $name }; CachedChildren = $kids } }
$known = @{ 'Running' = 'active'; 'Awaiting input' = 'needs'; 'Idle' = 'other'; 'Done' = 'other'; 'Mark as unread' = 'wrapper' }
$mr = @{ 'Mark as read' = 1 }
function Lbl($el) { $r = Get-CoworkRowLabel $el $known $mr; return "$($r.label)|$($r.wrapper)" }
Expect 'label named directly (Image Idle)' (Lbl (El 'Idle')) @('Idle|')
Expect 'label inside Mark as read (unread)' (Lbl (El 'Mark as read' @((El 'Done')))) @('Done|Mark as read')
Expect 'label inside Mark as unread (read)' (Lbl (El 'Mark as unread' @((El 'Done')))) @('Done|Mark as unread')
Expect 'running row of the 2026 app: Group > StatusBar Running' (Lbl (El '' @((El 'Running')))) @('Running|')
Expect 'label two levels down' (Lbl (El '' @((El '' @((El 'Awaiting input')))))) @('Awaiting input|')
Expect 'unknown label gives nothing' (Lbl (El '' @((El 'Thinking')))) @('|')

"`n$script:pass passed, $script:fail failed"
exit $script:fail
