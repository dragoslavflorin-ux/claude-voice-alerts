# Watcher Cowork: citeste starea conversatiilor din bara laterala a aplicatiei desktop Claude (UI Automation)
# si porneste alerta Cowork la tranzitii noi:
#   din Running in Mark as read (bulina albastra) = terminat
#   orice stare care devine Awaiting input (manuta galbena) = permisiune / raspuns
# Opreste alerta Cowork cand aplicatia Claude devine fereastra activa.
# O singura instanta (mutex). Ignora starea existenta la pornire. Log: watch.log (rotire la 1 MB).
# Depinde de etichetele in engleza ale aplicatiei Claude (Running, Awaiting input, Mark as read).
param([int]$PasMs = 500, [int]$CitireLaPasi = 3)
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
$hooks = Split-Path $dir -Parent
$logf = Join-Path $dir 'watch.log'
function L([string]$s) {
    try {
        if ((Test-Path $logf) -and (Get-Item $logf).Length -gt 1MB) { Move-Item $logf "$logf.1" -Force }
        Add-Content -Path $logf -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $s" -Encoding utf8
    } catch { }
}

$mx = New-Object System.Threading.Mutex($false, 'Local\ClaudeCoworkWatch')
if (-not $mx.WaitOne(0)) { exit 0 }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class CwFg {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static uint Pid() { uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p; }
}
'@

$pidCowork = Join-Path $env:TEMP 'claude-alerta-cowork.pid'
$condBtn = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$re = '^(Running|Awaiting input|Mark as read|Mark as unread|Idle) (.+)$'
$claudePids = @{}

# hashtable titlu = stare, sau $null daca aplicatia nu e pornita / arborele nu e gata
function Citeste {
    $script:claudePids = @{}
    $win = $null
    foreach ($p in Get-Process claude -ErrorAction SilentlyContinue) {
        $script:claudePids[[uint32]$p.Id] = 1
        if (-not $win -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $win = $p.MainWindowHandle }
    }
    if (-not $win) { return $null }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($win)
    $st = @{}
    foreach ($b in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condBtn)) {
        $n = $b.Current.Name
        if ($n -match $re) {
            $t = $Matches[2]
            if ($t -match '\s(\d+\s+new|New)$') { continue }   # sarcini programate (sectiunea Scheduled)
            $st[$t] = $Matches[1]
        }
    }
    if ($st.Count -eq 0) { return $null }
    return $st
}

L "start pid=$PID"
$prev = $null
$i = 0
while ($true) {
    try {
        $fgClaude = $claudePids.ContainsKey([CwFg]::Pid())
        # aplicatia Claude adusa in prim-plan: opreste doar alerta Cowork
        if ($fgClaude -and (Test-Path $pidCowork)) {
            & (Join-Path $hooks 'alerta-stop.ps1') -Ce cowork
            L 'alerta oprita: Claude in prim-plan'
        }
        if ($i % $CitireLaPasi -eq 0) {
            $cur = Citeste
            if ($null -eq $cur) {
                if ($null -ne $prev) { L 'stare indisponibila (aplicatia inchisa sau minimizata in tray)' }
                $prev = $null
            }
            elseif ($null -eq $prev) {
                $prev = $cur
                L "stare de baza: $($cur.Count) conversatii (semnalele vechi se ignora)"
            }
            else {
                $activePrev = @($prev.Keys | Where-Object { $prev[$_] -in 'Running', 'Awaiting input' })
                $disparut = @($activePrev | Where-Object { $cur[$_] -notin 'Running', 'Awaiting input' }).Count -gt 0
                $tip = $null; $cine = $null
                foreach ($t in $cur.Keys) {
                    $s = $cur[$t]; $p = $prev[$t]
                    if ($s -eq 'Awaiting input' -and $p -ne 'Awaiting input') { $tip = 'permisiune'; $cine = $t }
                    elseif ($s -eq 'Mark as read' -and $p -ne 'Mark as read' -and
                        ($p -in 'Running', 'Awaiting input' -or ($null -eq $p -and $disparut))) {
                        if ($tip -ne 'permisiune') { $tip = 'terminat'; $cine = $t }
                    }
                }
                if ($tip) {
                    $fgClaude = $claudePids.ContainsKey([CwFg]::Pid())
                    if ($fgClaude) { L "semnal $tip [$cine] ignorat: Claude e deja in prim-plan" }
                    else {
                        & (Join-Path $dir 'cowork-alerta.ps1') -Tip $tip
                        L "ALERTA $tip [$cine]"
                    }
                }
                $prev = $cur
            }
        }
    } catch { L "eroare: $_" }
    $i++
    Start-Sleep -Milliseconds $PasMs
}
