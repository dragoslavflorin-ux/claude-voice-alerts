# Hook Claude Code: porneste alerta vocala (fereastra in stanga jos) ca proces separat si ascuns, apoi iese imediat.
# Nu scrie nimic pe stdout.
param(
    [Parameter(Mandatory = $true)][ValidateSet('terminat', 'permisiune')][string]$Tip,
    [int]$MaxSeconds = 0
)
$ErrorActionPreference = 'SilentlyContinue'

# Apelat din hook-ul Notification: JSON pe stdin. Alerta doar pentru cereri de permisiune.
if ([Console]::IsInputRedirected) {
    $raw = [Console]::In.ReadToEnd()
    if ($raw -and $raw.Trim()) {
        $j = $null
        try { $j = $raw | ConvertFrom-Json } catch { }
        if ($j) {
            if ($j.PSObject.Properties.Name -contains 'notification_type') {
                if ($j.notification_type -ne 'permission_prompt') { exit 0 }
            }
            elseif ($Tip -eq 'permisiune' -and "$($j.message)" -notmatch 'permission') { exit 0 }
        }
    }
}

$dir = $PSScriptRoot
. (Join-Path $dir 'alerte-comun.ps1')
Porneste-Alerta -Parte 'claude_code' -Tip $Tip -MaxSeconds $MaxSeconds -Wav (Join-Path $dir "claude-code-$Tip.wav") `
    -PidNume 'claude-alerta.pid' -Ce 'code' -TitluImplicit 'Claude Code' -PozitieImplicita 'Stanga'
exit 0
