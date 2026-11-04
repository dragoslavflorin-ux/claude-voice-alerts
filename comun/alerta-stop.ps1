# Opreste bucla de alerta activa (daca exista). Nu scrie nimic si nu da erori.
# -Ce code (implicit, din hook-urile Claude Code) | cowork | toate (scurtatura Ctrl+Alt+M)
param([ValidateSet('code', 'cowork', 'toate')][string]$Ce = 'code')
$ErrorActionPreference = 'SilentlyContinue'
$fisiere = switch ($Ce) { 'code' { @('claude-alerta.pid') } 'cowork' { @('claude-alerta-cowork.pid') } 'toate' { @('claude-alerta.pid', 'claude-alerta-cowork.pid') } }
foreach ($nume in $fisiere) {
    $pidFile = Join-Path $env:TEMP $nume
    if (-not (Test-Path $pidFile)) { continue }
    $id = (Get-Content -Path $pidFile | Select-Object -First 1)
    Remove-Item -Path $pidFile -Force
    if ("$id" -match '^\d+$') {
        # opreste doar daca PID-ul e chiar o bucla de alerta (PID-urile se refolosesc)
        $p = Get-CimInstance Win32_Process -Filter "ProcessId = $id"
        if ($p -and $p.CommandLine -like '*alerta-loop.ps1*') { Stop-Process -Id $id -Force }
    }
}
exit 0
