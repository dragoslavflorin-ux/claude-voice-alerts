# Verifica alertele instalate: porneste fiecare alerta pentru cateva secunde, masoara fereastra, apoi o opreste.
# Rulare manuala: powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooks\verifica-alerte.ps1"
# Iesire: numarul de verificari picate (0 = totul e bine).
param([switch]$DoarClaudeCode, [switch]$DoarCowork)
$ErrorActionPreference = 'Continue'
$hooks = $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('VerAlerte' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class VerAlerte {
    public struct RECT { public int L, T, R, B; }
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr m, int t, out uint x, out uint y);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(System.Drawing.Point p, uint f);
    public static List<IntPtr> Of(uint pid) { var l = new List<IntPtr>(); EnumWindows((h, x) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) l.Add(h); return true; }, IntPtr.Zero); return l; }
    public static string Title(IntPtr h) { var s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }
}
'@
}
[void][VerAlerte]::SetProcessDpiAwarenessContext([IntPtr](-4))

$cfg = $null
try { $cfg = Get-Content (Join-Path $hooks 'alerte-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$dx = [uint32]96; $dy = [uint32]96
try { [void][VerAlerte]::GetDpiForMonitor([VerAlerte]::MonitorFromPoint((New-Object System.Drawing.Point 0, 0), 1), 0, [ref]$dx, [ref]$dy) } catch { }
$margineCfg = if ($cfg -and $null -ne $cfg.margine_px) { [int]$cfg.margine_px } else { 16 }
$m = [int][Math]::Round($margineCfg * $dx / 96.0)
"Ecran principal: zona de lucru $($wa.Width)x$($wa.Height), scalare $([int]($dx / 96 * 100))%, margine asteptata $m px fizici"

$script:ok = 0; $script:picate = 0
function Verifica([bool]$bun, [string]$text) {
    if ($bun) { $script:ok++; "  OK      $text" } else { $script:picate++; "  EROARE  $text" }
}
function Viu($id) { [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }

function Test-Parte($nume, $start, $pidNume, $titlu, $pozitie, $ce, $wavuri) {
    "${nume}:"
    foreach ($w in $wavuri) { Verifica (Test-Path $w) "fisier audio $(Split-Path $w -Leaf)" }
    $pidFile = Join-Path $env:TEMP $pidNume
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = '' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -Tip terminat -MaxSeconds 30 | Out-String
    $ms = $sw.ElapsedMilliseconds
    Verifica (-not $out.Trim()) 'scriptul de start nu scrie nimic pe ecran'
    Verifica ($ms -lt 2000) "scriptul de start iese in $ms ms (sub 2000)"
    $x = $null
    for ($i = 0; $i -lt 40 -and -not $x; $i++) {
        $id = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ("$id" -match '^\d+$') { foreach ($h in [VerAlerte]::Of([uint32]$id)) { if ([VerAlerte]::Title($h) -eq $titlu) { $x = @{ h = $h; id = [int]$id } } } }
        if (-not $x) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $x) { R $false "fereastra '$titlu' nu a aparut"; return }
    Start-Sleep -Milliseconds 500
    $r = New-Object VerAlerte+RECT; [void][VerAlerte]::GetWindowRect($x.h, [ref]$r)
    $lat = if ($pozitie -eq 'Dreapta') { $wa.Right - $r.R } else { $r.L - $wa.Left }
    $jos = $wa.Bottom - $r.B
    $poz = if ($pozitie -eq 'Dreapta') { 'dreapta' } else { 'stanga' }
    Verifica ([Math]::Abs($lat - $m) -le 1 -and [Math]::Abs($jos - $m) -le 1) "fereastra in $poz jos: $lat px de margine laterala, $jos px de jos (L=$($r.L) T=$($r.T) R=$($r.R) B=$($r.B))"
    $ex = [VerAlerte]::GetWindowLong($x.h, -20)
    Verifica (($ex -band 0x08000000) -and ($ex -band 0x8)) 'fereastra sta deasupra si nu fura focusul'
    & (Join-Path $hooks 'alerta-stop.ps1') -Ce $ce
    Start-Sleep -Milliseconds 800
    Verifica (-not (Viu $x.id) -and -not (Test-Path $pidFile)) 'scriptul de stop inchide alerta'
}

if (-not $DoarCowork) {
    Test-Parte 'Claude Code' (Join-Path $hooks 'alerta-start.ps1') 'claude-alerta.pid' "$(if ($cfg.claude_code.titlu) { $cfg.claude_code.titlu } else { 'Claude Code' })" `
        "$(if ($cfg.claude_code.pozitie -eq 'Dreapta') { 'Dreapta' } else { 'Stanga' })" 'code' `
        @((Join-Path $hooks 'claude-code-terminat.wav'), (Join-Path $hooks 'claude-code-permisiune.wav'))
}
if (-not $DoarClaudeCode) {
    $cw = Join-Path $hooks 'cowork'
    Test-Parte 'Cowork' (Join-Path $cw 'cowork-alerta.ps1') 'claude-alerta-cowork.pid' "$(if ($cfg.cowork.titlu) { $cfg.cowork.titlu } else { 'Claude Cowork' })" `
        "$(if ($cfg.cowork.pozitie -eq 'Stanga') { 'Stanga' } else { 'Dreapta' })" 'cowork' `
        @((Join-Path $cw 'cowork-terminat.wav'), (Join-Path $cw 'cowork-permisiune.wav'))
}
"VERIFICARE: $($script:ok) OK, $($script:picate) erori"
exit $script:picate
