# Cod comun pentru pornirea alertelor: citeste alerte-config.json si porneste bucla ascunsa (alerta-loop.ps1).
# Se incarca cu dot-source din alerta-start.ps1 (Claude Code) si cowork\cowork-alerta.ps1 (Cowork).

function Citeste-ConfigAlerte {
    $f = Join-Path $PSScriptRoot 'alerte-config.json'
    try { return (Get-Content -Path $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Porneste-Alerta {
    param(
        [string]$Parte,            # claude_code | cowork (cheia din config)
        [string]$Tip,              # terminat | permisiune
        [int]$MaxSeconds,          # 0 = din config
        [string]$Wav,
        [string]$PidNume,
        [string]$Ce,               # code | cowork (pentru alerta-stop.ps1)
        [string]$TitluImplicit,
        [string]$PozitieImplicita
    )
    $hooks = $PSScriptRoot
    $cfg = Citeste-ConfigAlerte
    $p = if ($cfg) { $cfg.$Parte } else { $null }

    $mesaj = if ($p -and $p.texte) { "$($p.texte.$Tip)" } else { '' }
    if (-not $mesaj) { $mesaj = $TitluImplicit }
    $titlu = if ($p -and $p.titlu) { "$($p.titlu)" } else { $TitluImplicit }
    $pozitie = if ($p -and $p.pozitie -in 'Stanga', 'Dreapta') { "$($p.pozitie)" } else { $PozitieImplicita }
    if ($MaxSeconds -le 0 -and $cfg) { $MaxSeconds = [int]$cfg.limita_secunde }
    if ($MaxSeconds -le 0) { $MaxSeconds = 300 }
    $pauza = if ($cfg -and $null -ne $cfg.pauza_secunde) { [int]$cfg.pauza_secunde } else { 5 }
    $margine = if ($cfg -and $null -ne $cfg.margine_px) { [int]$cfg.margine_px } else { 16 }

    & (Join-Path $hooks 'alerta-stop.ps1') -Ce $Ce

    $loop = Join-Path $hooks 'alerta-loop.ps1'
    $proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$loop`"", '-Wav', "`"$Wav`"", '-MaxSeconds', $MaxSeconds, '-PauzaSec', $pauza,
        '-Mesaj', "`"$mesaj`"", '-Pozitie', $pozitie, '-PidFile', $PidNume, '-Titlu', "`"$titlu`"", '-Margine', $margine)
    # PID scris si aici, ca un stop imediat sa gaseasca bucla chiar inainte sa porneasca ea
    if ($proc) { Set-Content -Path (Join-Path $env:TEMP $PidNume) -Value $proc.Id -Encoding ascii }
}
