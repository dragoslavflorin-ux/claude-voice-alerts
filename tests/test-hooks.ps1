# End-to-end test of the Claude Code hooks, run exactly like Claude Code runs them: the command strings from
# settings.json, through Git Bash, with the hook JSON (UTF-8) on stdin. Needs an install made with -Root.
#   powershell -ExecutionPolicy Bypass -File tests\test-hooks.ps1 -Root <test folder> [-Shots <folder>]
param([Parameter(Mandatory = $true)][string]$Root, [string]$Shots)
$ErrorActionPreference = 'Continue'
$Root = [IO.Path]::GetFullPath($Root)
$settings = Get-Content -LiteralPath (Join-Path $Root '.claude\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$state = Join-Path $Root 'state'
$bash = "$env:ProgramFiles\Git\bin\bash.exe"
$script:pass = 0; $script:fail = 0
function Check([bool]$c, [string]$t) { if ($c) { $script:pass++; "PASS  $t" } else { $script:fail++; "FAIL  $t" } }
function Cmd([string]$ev, [string]$tool) {
    foreach ($g in @($settings.hooks.$ev)) {
        if ($tool -and $g.matcher -and $tool -notmatch "^($($g.matcher))$") { continue }
        foreach ($h in @($g.hooks)) { if ($h.command -like '*claude-voice-alerts*') { return $h.command } }
    }
    return $null
}
function Run-Hook([string]$ev, [hashtable]$data) {
    $cmd = if ($ev -eq 'Empty') { 'exit 0' } else { Cmd $ev $data.tool_name }
    if ($ev -eq 'Notification' -and $data.notification_type -and $data.notification_type -notmatch '^(permission_prompt|elicitation_dialog)$') { $cmd = $null }
    if (-not $cmd) { return -1 }
    # same field order as Claude Code: session_id first
    $o = [ordered]@{ session_id = $data.session_id; transcript_path = 'C:\Users\x\.claude\projects\p\t.jsonl'; cwd = $data.cwd; hook_event_name = $ev }
    foreach ($k in $data.Keys) { if (-not $o.Contains($k)) { $o[$k] = $data[$k] } }
    $json = [PSCustomObject]$o | ConvertTo-Json -Compress
    $psi = New-Object Diagnostics.ProcessStartInfo $bash
    $psi.Arguments = '-c "' + ($cmd -replace '\\', '\\' -replace '"', '\"') + '"'
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $b = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    try { $p.StandardInput.BaseStream.Write($b, 0, $b.Length); $p.StandardInput.Close() } catch { }   # the hook may stop reading early (like any hook that ignores stdin)
    $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    if ($out.Trim()) { "      (stdout not empty: $out)" | Out-Host }
    return $sw.Elapsed.TotalMilliseconds
}
function Alerts { @(Get-ChildItem -LiteralPath (Join-Path $state 'alerts') -Filter 'code-*.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }) }
function Wait-Hub([int]$n) { for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 250; if ((Alerts).Count -eq $n) { break } }; Start-Sleep -Milliseconds 600 }
$A = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'; $B = 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'
$cwdA = 'C:\Proiecte clienti\Țara Bârsei'; $cwdB = 'C:\work\website-redesign'

'--- test 1: two sessions'
Run-Hook 'UserPromptSubmit' @{ session_id = $A; cwd = $cwdA; prompt = 'x' } | Out-Null
Run-Hook 'UserPromptSubmit' @{ session_id = $B; cwd = $cwdB; prompt = 'y' } | Out-Null
$t = Run-Hook 'Stop' @{ session_id = $A; cwd = $cwdA; stop_hook_active = $false }
Check ((Alerts) -contains "code-$A") "A finished: alert for A (Stop hook $([int]$t) ms)"
Run-Hook 'PostToolUse' @{ session_id = $B; cwd = $cwdB; tool_name = 'Bash' } | Out-Null
Check ((Alerts) -contains "code-$A") 'B used a tool: the alert of A is still there'
Run-Hook 'Stop' @{ session_id = $B; cwd = $cwdB } | Out-Null
Wait-Hub 2
Check ((Alerts).Count -eq 2) "B finished: two alerts ($((Alerts) -join ', '))"
$e = Get-Content -LiteralPath (Join-Path $state "alerts\code-$A.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Check ($e.project -eq 'Țara Bârsei') "project name with diacritics and spaces in the path: [$($e.project)]"
if ($Shots) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Shots 'winfo.ps1') -Crop (Join-Path $Shots 'hooks-two') }
Run-Hook 'UserPromptSubmit' @{ session_id = $A; cwd = $cwdA; prompt = 'next' } | Out-Null
Check (((Alerts) -notcontains "code-$A") -and ((Alerts) -contains "code-$B")) 'new prompt in A removes only the row of A'
Run-Hook 'UserPromptSubmit' @{ session_id = $B; cwd = $cwdB; prompt = 'next' } | Out-Null

'--- test 2: PostToolUse without an alert of its own session'
$big = 'x' * 300000   # a Read of a large file: the tool output travels on stdin
$times = @(); $tbig = @(); $base = @()
for ($i = 0; $i -lt 21; $i++) {
    $base += Run-Hook 'Empty' @{ session_id = $B; cwd = $cwdB }
    $times += Run-Hook 'PostToolUse' @{ session_id = $B; cwd = $cwdB; tool_name = 'Read'; tool_input = @{ file_path = 'C:\a.txt' }; tool_response = 'ok' }
    $tbig += Run-Hook 'PostToolUse' @{ session_id = $B; cwd = $cwdB; tool_name = 'Read'; tool_input = @{ file_path = 'C:\big.txt' }; tool_response = $big }
}
$s = $times | Sort-Object; $sb = $tbig | Sort-Object; $bs = $base | Sort-Object
"      empty bash (same harness): median $([int]$bs[10]) ms, min $([int]$bs[0])"
Check (($s[10] - $bs[10]) -lt 10) "PostToolUse, small input: median $([int]$s[10]) ms (min $([int]$s[0]), max $([int]$s[-1])), $([int]($s[10] - $bs[10])) ms over an empty bash"
Check (($sb[10] - $bs[10]) -lt 10) "PostToolUse, 300 KB tool output on stdin: median $([int]$sb[10]) ms (min $([int]$sb[0]), max $([int]$sb[-1])), $([int]($sb[10] - $bs[10])) ms over an empty bash"

'--- test 3: needs you (permission, question, plan) and its end'
Run-Hook 'Notification' @{ session_id = $A; cwd = $cwdA; notification_type = 'permission_prompt'; message = 'Claude needs your permission to use Bash' } | Out-Null
$k = (Get-Content -LiteralPath (Join-Path $state "alerts\code-$A.json") -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).kind
Check ($k -eq 'needs') "permission_prompt gives 'needs' ($k)"
Run-Hook 'PostToolUse' @{ session_id = $A; cwd = $cwdA; tool_name = 'Bash' } | Out-Null
Check ((Alerts) -notcontains "code-$A") 'after approval (tool ran) the alert is gone'
foreach ($tool in 'AskUserQuestion', 'ExitPlanMode') {
    Run-Hook 'PreToolUse' @{ session_id = $A; cwd = $cwdA; tool_name = $tool } | Out-Null
    $k = (Get-Content -LiteralPath (Join-Path $state "alerts\code-$A.json") -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).kind
    Check ($k -eq 'needs') "$tool gives 'needs' ($k)"
    Run-Hook 'PostToolUse' @{ session_id = $A; cwd = $cwdA; tool_name = $tool } | Out-Null
    Check ((Alerts) -notcontains "code-$A") "after the answer ($tool PostToolUse) the alert is gone"
}
Run-Hook 'PreToolUse' @{ session_id = $A; cwd = $cwdA; tool_name = 'Bash' } | Out-Null
Check ((Alerts) -notcontains "code-$A") 'PreToolUse of another tool (Bash) gives no alert'
Run-Hook 'Notification' @{ session_id = $A; cwd = $cwdA; notification_type = 'idle_prompt' } | Out-Null
Check ((Alerts) -notcontains "code-$A") 'idle_prompt notification gives no alert'

"`n$script:pass passed, $script:fail failed"
exit $script:fail
