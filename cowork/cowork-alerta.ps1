# Porneste alerta Cowork (fereastra in dreapta jos) ca proces separat si ascuns, apoi iese imediat.
# Refoloseste ..\alerta-loop.ps1. Fisier PID separat de Claude Code: %TEMP%\claude-alerta-cowork.pid
param(
    [Parameter(Mandatory = $true)][ValidateSet('terminat', 'permisiune')][string]$Tip,
    [int]$MaxSeconds = 0
)
$ErrorActionPreference = 'SilentlyContinue'
$dir = $PSScriptRoot
. (Join-Path (Split-Path $dir -Parent) 'alerte-comun.ps1')
Porneste-Alerta -Parte 'cowork' -Tip $Tip -MaxSeconds $MaxSeconds -Wav (Join-Path $dir "cowork-$Tip.wav") `
    -PidNume 'claude-alerta-cowork.pid' -Ce 'cowork' -TitluImplicit 'Claude Cowork' -PozitieImplicita 'Dreapta'
exit 0
