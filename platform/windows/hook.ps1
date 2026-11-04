# Claude Code hook: adds an alert for THIS session (Stop = done, Needs = permission / question / plan approval).
# Reads the hook JSON from stdin as UTF-8. Prints nothing. Must return fast (it only writes one small file).
# The fast "clear" path (PostToolUse / UserPromptSubmit) lives in fast.sh and never starts PowerShell.
param([Parameter(Mandatory = $true)][ValidateSet('Stop', 'Needs', 'Clear')][string]$Event)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib.ps1')

$raw = ''
try {
    $sr = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
    $raw = $sr.ReadToEnd()
} catch { }
$j = $null
try { $j = $raw | ConvertFrom-Json } catch { }
$sid = "$($j.session_id)"
if (-not $sid) { exit 0 }
$cfg = Get-CvaConfig

if ($Event -eq 'Clear') {
    # PowerShell fallback for machines without Git Bash (same job as fast.sh)
    $state = Get-CvaStateDir $cfg
    if ($j.hook_event_name -eq 'UserPromptSubmit') { [IO.File]::WriteAllText((Join-Path $state "start\code-$sid"), "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())") }
    [void](Remove-CvaAlert $cfg 'code' $sid)
    exit 0
}

if (@($cfg.parts) -notcontains 'code') { exit 0 }
$cwd = "$($j.cwd)"
$project = if ($cwd) { Split-Path $cwd -Leaf } else { 'Claude Code' }
if (-not $project) { $project = $cwd }

if ($Event -eq 'Stop') {
    $min = [int]$cfg.min_task_seconds
    if ($min -gt 0) {
        $sf = Join-Path (Get-CvaStateDir $cfg) "start\code-$sid"
        $t0 = 0; [void][long]::TryParse(("$(Get-Content -LiteralPath $sf -TotalCount 1)").Trim(), [ref]$t0)
        $dur = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $t0
        if ($t0 -gt 0 -and $dur -lt $min) { Write-CvaLog 'hook' "skip done [$project]: task took $dur s (< min_task_seconds $min)"; exit 0 }
    }
    $kind = 'done'
}
else {
    $nt = "$($j.notification_type)"
    if ($j.hook_event_name -eq 'Notification' -and $nt -and $nt -notin 'permission_prompt', 'elicitation_dialog') { exit 0 }
    $kind = 'needs'
}

# What to bring to front when the user clicks the row
$focus = @{}
try {
    if (-not ('CvaHookNative' -as [type])) {
        Add-Type @'
using System; using System.Runtime.InteropServices;
public static class CvaHookNative {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
}
'@
    }
    $cw = [CvaHookNative]::GetConsoleWindow()
    if ($cw -ne [IntPtr]::Zero) { $focus['console_window'] = [long][CvaHookNative]::GetAncestor($cw, 3) }
} catch { }
if ($env:VSCODE_GIT_ASKPASS_NODE) { $focus['host_exe'] = [IO.Path]::GetFileNameWithoutExtension($env:VSCODE_GIT_ASKPASS_NODE) }
elseif ($env:TERM_PROGRAM -eq 'vscode') { $focus['host_exe'] = 'Code' }
if ($env:WT_SESSION) { $focus['terminal'] = 'WindowsTerminal' }
$focus['cwd'] = $cwd
$focus['tool'] = "$($j.tool_name)"

Add-CvaAlert $cfg 'code' $sid $kind $project $focus
Write-CvaLog 'hook' "$kind [$project] session=$($sid.Substring(0, [Math]::Min(8, $sid.Length))) event=$($j.hook_event_name) $($j.notification_type)$($j.tool_name)"
exit 0
