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
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class CvaHookNative {
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll")] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint f, uint p);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr s, ref PE e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr s, ref PE e);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct PE {
        public uint size, usage, pid; public IntPtr heap; public uint module, threads, parent; public int prio; public uint flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string exe; }
    // Window that shows the console of this session: the console window itself (conhost) or its root owner
    // (Windows Terminal owns the hidden pseudo console window of each tab). Hooks usually run without a console,
    // so we attach to the console of the nearest ancestor (claude.exe and the shell that started it).
    public static long TerminalWindow() {
        IntPtr cw = GetConsoleWindow();
        if (cw != IntPtr.Zero) return (long)GetAncestor(cw, 3);
        var parent = new Dictionary<uint, uint>();
        IntPtr snap = CreateToolhelp32Snapshot(2, 0);
        var e = new PE(); e.size = (uint)Marshal.SizeOf(typeof(PE));
        if (Process32FirstW(snap, ref e)) { do { parent[e.pid] = e.parent; } while (Process32NextW(snap, ref e)); }
        CloseHandle(snap);
        uint pid = GetCurrentProcessId();
        FreeConsole();   // a console without a window (CREATE_NO_WINDOW) would make AttachConsole fail
        for (int i = 0; i < 8; i++) {
            uint pp; if (!parent.TryGetValue(pid, out pp) || pp == 0 || pp == pid) break;
            pid = pp;
            if (AttachConsole(pid)) { cw = GetConsoleWindow(); IntPtr r = cw == IntPtr.Zero ? IntPtr.Zero : GetAncestor(cw, 3); FreeConsole(); if (cw != IntPtr.Zero) return (long)r; }
        }
        return 0;
    }
}
'@
    }
    $tw = [CvaHookNative]::TerminalWindow()
    if ($tw -ne 0) { $focus['console_window'] = $tw }
} catch { }
if ($env:VSCODE_GIT_ASKPASS_NODE) { $focus['host_exe'] = [IO.Path]::GetFileNameWithoutExtension($env:VSCODE_GIT_ASKPASS_NODE) }
elseif ($env:TERM_PROGRAM -eq 'vscode') { $focus['host_exe'] = 'Code' }
if ($env:WT_SESSION) { $focus['terminal'] = 'WindowsTerminal' }
$focus['cwd'] = $cwd
$focus['tool'] = "$($j.tool_name)"

Add-CvaAlert $cfg 'code' $sid $kind $project $focus
Write-CvaLog 'hook' "$kind [$project] session=$($sid.Substring(0, [Math]::Min(8, $sid.Length))) event=$($j.hook_event_name) $($j.notification_type)$($j.tool_name)"
exit 0
