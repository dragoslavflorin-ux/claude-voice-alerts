# Instaleaza alertele vocale pentru Claude Code si Claude Cowork pe Windows.
# Rulare:  powershell -ExecutionPolicy Bypass -File .\install.ps1 [-DoarClaudeCode | -DoarCowork] [-FaraVerificare]
# Idempotent: poate fi rulat de cate ori vrei; actualizeaza o instalare mai veche.
param([switch]$DoarClaudeCode, [switch]$DoarCowork, [switch]$FaraVerificare)
$ErrorActionPreference = 'Continue'
$VERSIUNE = '1.0.0'

if ($DoarClaudeCode -and $DoarCowork) { Write-Host 'Alege cel mult una dintre -DoarClaudeCode si -DoarCowork.' -ForegroundColor Red; exit 1 }
$repo = $PSScriptRoot
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$hooks = Join-Path $claudeDir 'hooks'
$cwDir = Join-Path $hooks 'cowork'
$settings = Join-Path $claudeDir 'settings.json'
$manifest = Join-Path $hooks 'alerte-install.json'
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Opreste vocea Claude.lnk'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Cowork watcher.lnk'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# partile deja instalate raman instalate (o rulare -DoarCowork nu scoate Claude Code)
$vechi = $null
if (Test-Path $manifest) { try { $vechi = Get-Content $manifest -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
$parti = @()
if (-not $DoarCowork) { $parti += 'claude_code' }
if (-not $DoarClaudeCode) { $parti += 'cowork' }
if ($vechi -and $vechi.parti) { $parti = @(@($parti) + @($vechi.parti) | Select-Object -Unique) }
$code = $parti -contains 'claude_code'
$cowork = $parti -contains 'cowork'

function Pas([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Info([string]$t) { Write-Host "   $t" }
function Avertizare([string]$t) { Write-Host "   ATENTIE: $t" -ForegroundColor Yellow; $script:avertizari += $t }
function Opreste([string]$t) { Write-Host "   EROARE: $t" -ForegroundColor Red; exit 1 }
$script:avertizari = @()
function Reimprospateaza-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

# ---------------------------------------------------------------- config
Pas 'Citesc config.json'
try { $cfg = Get-Content (Join-Path $repo 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Opreste "config.json nu e JSON valid: $_" }
foreach ($p in 'claude_code', 'cowork') {
    foreach ($t in 'terminat', 'permisiune') { if (-not "$($cfg.$p.texte.$t)".Trim()) { Opreste "lipseste textul $p.texte.$t din config.json" } }
    if (-not "$($cfg.$p.voce)".Trim()) { Opreste "lipseste vocea $p.voce din config.json" }
}
$taste = @("$($cfg.hotkey)" -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$hotkey = ($taste | ForEach-Object { switch -Regex ($_) { '^(ctrl|control)$' { 'CTRL' } '^alt$' { 'ALT' } '^shift$' { 'SHIFT' } default { $_.ToUpper() } } }) -join '+'
if ($taste.Count -lt 2) { Opreste "hotkey invalid in config.json: '$($cfg.hotkey)' (exemplu: Ctrl+Alt+M)" }
Info "parti de instalat: $($parti -join ', ')"

# ---------------------------------------------------------------- dependinte
function Gaseste-Python {
    $cand = @()
    foreach ($c in 'py', 'python', 'python3') { $g = Get-Command $c -ErrorAction SilentlyContinue; if ($g) { $cand += $g.Source } }
    $cand += @(Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | ForEach-Object FullName)
    foreach ($c in $cand) {
        if ($c -like '*\WindowsApps\*') { continue }   # aliasul Microsoft Store nu e Python real
        $v = & $c -c 'import sys; print(sys.version_info[0])' 2>$null
        if ("$v".Trim() -eq '3') { return $c }
    }
    return $null
}
function Gaseste-Ffmpeg {
    $g = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    $f = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg*\*\bin\ffmpeg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}
function Winget-Instaleaza([string]$id) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Opreste "lipseste winget. Instaleaza 'App Installer' din Microsoft Store sau instaleaza manual $id, apoi ruleaza din nou." }
    Info "instalez $id prin winget (poate dura cateva minute)..."
    & winget install -e --id $id --scope user --silent --accept-source-agreements --accept-package-agreements | Out-Null
    if ($LASTEXITCODE -ne 0) { & winget install -e --id $id --silent --accept-source-agreements --accept-package-agreements | Out-Null }
    Reimprospateaza-Path
}

Pas 'Verific Python, edge-tts si ffmpeg'
$py = Gaseste-Python
if (-not $py) { Winget-Instaleaza 'Python.Python.3.12'; $py = Gaseste-Python }
if (-not $py) { Opreste 'Python nu a putut fi instalat. Instaleaza-l de pe python.org, apoi ruleaza din nou.' }
Info "Python: $py"
& $py -m edge_tts --version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Info 'instalez edge-tts prin pip...'
    & $py -m pip install --user --upgrade --quiet --disable-pip-version-check edge-tts 2>$null | Out-Null
    & $py -m edge_tts --version 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Opreste 'edge-tts nu a putut fi instalat (pip install edge-tts).' }
}
Info 'edge-tts: OK'
$ff = Gaseste-Ffmpeg
if (-not $ff) { Winget-Instaleaza 'Gyan.FFmpeg'; $ff = Gaseste-Ffmpeg }
if (-not $ff) { Opreste 'ffmpeg nu a putut fi instalat. Instaleaza-l manual (winget install Gyan.FFmpeg), apoi ruleaza din nou.' }
Info "ffmpeg: $ff"

# ---------------------------------------------------------------- opresc ce ruleaza
Pas 'Opresc alertele si watcher-ul care ruleaza acum'
$oprite = 0
foreach ($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue) {
    if ($p.CommandLine -like '*cowork-watch.ps1*' -or $p.CommandLine -like '*alerta-loop.ps1*') { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $oprite++ }
}
foreach ($n in 'claude-alerta.pid', 'claude-alerta-cowork.pid') { Remove-Item (Join-Path $env:TEMP $n) -Force -ErrorAction SilentlyContinue }
Info "procese oprite: $oprite"

# ---------------------------------------------------------------- fisiere
Pas "Copiez fisierele in $hooks"
New-Item -ItemType Directory -Force -Path $hooks | Out-Null
$fisiere = New-Object System.Collections.Generic.List[string]
function Copiaza([string]$sursa, [string]$dest) {
    Copy-Item -Path $sursa -Destination $dest -Force -ErrorAction Stop
    $script:fisiere.Add($dest)
}
foreach ($f in Get-ChildItem (Join-Path $repo 'comun') -File) { Copiaza $f.FullName (Join-Path $hooks $f.Name) }
Copiaza (Join-Path $repo 'config.json') (Join-Path $hooks 'alerte-config.json')
if ($code) { foreach ($f in Get-ChildItem (Join-Path $repo 'alerte') -File) { Copiaza $f.FullName (Join-Path $hooks $f.Name) } }
if ($cowork) {
    New-Item -ItemType Directory -Force -Path $cwDir | Out-Null
    foreach ($f in Get-ChildItem (Join-Path $repo 'cowork') -File) { Copiaza $f.FullName (Join-Path $cwDir $f.Name) }
}
# fisiere audio cu nume vechi, din versiuni anterioare
foreach ($v in 'm-am-terminat.mp3', 'm-am-terminat.wav', 'am-nevoie-de-tine.mp3', 'am-nevoie-de-tine.wav',
    'cowork\si-eu-m-am-terminat.mp3', 'cowork\si-eu-m-am-terminat.wav', 'cowork\si-eu-am-nevoie-de-tine.mp3', 'cowork\si-eu-am-nevoie-de-tine.wav') {
    $c = Join-Path $hooks $v; if (Test-Path $c) { Remove-Item $c -Force; Info "sters fisier vechi: $v" }
}
Info "fisiere copiate: $($fisiere.Count)"

# ---------------------------------------------------------------- audio
Pas 'Generez vocile cu edge-tts'
$amprenteF = Join-Path $hooks 'alerte-audio.json'
$amprente = @{}
if (Test-Path $amprenteF) { try { (Get-Content $amprenteF -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $amprente[$_.Name] = $_.Value } } catch { } }
$audio = @()
if ($code) { foreach ($t in 'terminat', 'permisiune') { $audio += @{ wav = Join-Path $hooks "claude-code-$t.wav"; voce = $cfg.claude_code.voce; text = $cfg.claude_code.texte.$t } } }
if ($cowork) { foreach ($t in 'terminat', 'permisiune') { $audio += @{ wav = Join-Path $cwDir "cowork-$t.wav"; voce = $cfg.cowork.voce; text = $cfg.cowork.texte.$t } } }
foreach ($a in $audio) {
    $nume = Split-Path $a.wav -Leaf
    $amp = "$($a.voce)|$($a.text)"
    $fisiere.Add($a.wav)
    if ((Test-Path $a.wav) -and $amprente[$nume] -eq $amp) { Info "$nume neschimbat"; continue }
    $mp3 = Join-Path $env:TEMP "alerte-$([guid]::NewGuid().ToString('N')).mp3"
    & $py -m edge_tts --voice $a.voce --text $a.text --write-media $mp3 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $mp3)) { Opreste "edge-tts nu a generat $nume (verifica internetul si numele vocii '$($a.voce)')" }
    & $ff -y -loglevel error -i $mp3 -ac 1 -ar 44100 -c:a pcm_s16le -map_metadata -1 -fflags +bitexact $a.wav 2>$null
    Remove-Item $mp3 -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $a.wav)) { Opreste "ffmpeg nu a convertit $nume" }
    $amprente[$nume] = $amp
    Info "$nume generat: '$($a.text)' cu $($a.voce)"
}
$amprente | ConvertTo-Json | Set-Content -Path $amprenteF -Encoding UTF8
$fisiere.Add($amprenteF)

# ---------------------------------------------------------------- settings.json
$setariPy = Join-Path $repo 'instalare\setari_hooks.py'
if ($code) {
    Pas 'Adaug hook-urile in ~/.claude/settings.json'
    if (Test-Path $settings) {
        $bak = "$settings.bak-alerte-$stamp"
        Copy-Item $settings $bak -Force -ErrorAction Stop
        Info "backup: $bak"
    }
    $r = & $py $setariPy adauga $settings $hooks
    if ($LASTEXITCODE -ne 0) { Opreste "nu am putut actualiza settings.json (backup-ul e neatins). $r" }
    Info "$r (hook-urile vechi ale alertelor sunt inlocuite, restul setarilor raman neatinse)"
}

# ---------------------------------------------------------------- scurtatura Ctrl+Alt+M
Pas "Creez scurtatura de pe Desktop ($($cfg.hotkey))"
$sh = New-Object -ComObject WScript.Shell
$l = $sh.CreateShortcut($desktopLnk)
$l.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$l.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $hooks 'alerta-stop.ps1')`" -Ce toate"
$l.WindowStyle = 7
$l.Hotkey = $hotkey
$l.Description = 'Opreste alertele vocale Claude Code si Cowork'
$l.IconLocation = "$env:SystemRoot\System32\SHELL32.dll,109"
$l.Save()
Info "$desktopLnk (tasta: $hotkey)"

# ---------------------------------------------------------------- pornire automata watcher
if ($cowork) {
    Pas 'Configurez pornirea automata a watcher-ului Cowork la logare'
    $s = $sh.CreateShortcut($startupLnk)
    $s.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $s.Arguments = "`"$(Join-Path $cwDir 'cowork-watch-start.vbs')`""
    $s.WorkingDirectory = $cwDir
    $s.Description = 'Watcher alerte Claude Cowork'
    $s.Save()
    Info $startupLnk
}

# ---------------------------------------------------------------- manifest
$m = [ordered]@{
    versiune   = $VERSIUNE
    instalat   = (Get-Date -Format 's')
    parti      = @($parti)
    fisiere    = @($fisiere | Select-Object -Unique)
    scurtatura = $desktopLnk
    pornire    = if ($cowork) { $startupLnk } else { $null }
}
$m | ConvertTo-Json | Set-Content -Path $manifest -Encoding UTF8

# ---------------------------------------------------------------- verificare
$rezVer = 'sarita (-FaraVerificare)'
if (-not $FaraVerificare) {
    Pas 'Verific instalarea (pornesc fiecare alerta cateva secunde, o masor si o opresc)'
    $argsV = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $hooks 'verifica-alerte.ps1'))
    if (-not $code) { $argsV += '-DoarCowork' }
    if (-not $cowork) { $argsV += '-DoarClaudeCode' }
    & powershell.exe @argsV | ForEach-Object { Write-Host "   $_" }
    $rezVer = if ($LASTEXITCODE -eq 0) { 'toate verificarile au trecut' } else { "$LASTEXITCODE verificari picate (vezi mai sus)" }
    if ($LASTEXITCODE -ne 0) { $script:avertizari += 'verificarea automata a gasit probleme' }
    $lk = $sh.CreateShortcut($desktopLnk)
    if ($lk.Hotkey -and (Test-Path $desktopLnk)) { Info "OK      scurtatura exista, tasta $($lk.Hotkey)" } else { Avertizare 'scurtatura de pe Desktop nu are tasta setata' }
    if ($cowork) { if (Test-Path $startupLnk) { Info 'OK      pornirea automata a watcher-ului e configurata' } else { Avertizare 'pornirea automata lipseste' } }
}

# ---------------------------------------------------------------- pornesc watcher-ul
if ($cowork) {
    Pas 'Pornesc watcher-ul Cowork'
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList "`"$(Join-Path $cwDir 'cowork-watch-start.vbs')`""
    $w = $null
    for ($i = 0; $i -lt 20 -and -not $w; $i++) {
        Start-Sleep -Milliseconds 500
        $w = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*cowork-watch.ps1*' }
    }
    if ($w) { Info "watcher pornit (pid $(@($w)[0].ProcessId))" } else { Avertizare 'watcher-ul nu a pornit; vezi cowork\watch.log' }
}

# ---------------------------------------------------------------- rezumat
Write-Host ''
Write-Host '================ REZUMAT ================' -ForegroundColor Green
Write-Host "Versiune:      $VERSIUNE"
Write-Host "Instalat in:   $hooks"
Write-Host "Parti:         $(if ($code) { 'Claude Code (fereastra in stanga jos) ' })$(if ($cowork) { 'Cowork (fereastra in dreapta jos)' })"
Write-Host "Verificare:    $rezVer"
Write-Host "Oprire:        click pe fereastra sau $($cfg.hotkey) (opreste toate alertele)"
Write-Host ''
Write-Host 'De facut manual:' -ForegroundColor Yellow
if ($code) {
    Write-Host '  Claude Code: inchide si redeschide sesiunile Claude Code deschise, ca sa incarce hook-urile noi.'
}
if ($cowork) {
    Write-Host '  Cowork: detectia citeste lista de conversatii din aplicatia desktop Claude. Ca sa mearga:'
    Write-Host '    1. aplicatia Claude trebuie sa fie pornita, cu fereastra deschisa (poate fi in spate, dar nu inchisa in tray);'
    Write-Host '    2. interfata aplicatiei in limba engleza (watcher-ul cauta etichetele Running, Awaiting input, Mark as read);'
    Write-Host '    3. conversatiile Cowork vizibile in bara laterala din stanga a aplicatiei.'
    Write-Host '    Alerta Cowork nu suna cat timp aplicatia Claude e fereastra activa (atunci vezi oricum ce s-a intamplat).'
    Write-Host '    Notificarile din setarile aplicatiei Claude NU sunt necesare.'
}
Write-Host '  Windows: volumul sa nu fie pe mut. Scurtatura de pe Desktop trebuie sa ramana pe Desktop, altfel tasta nu merge.'
if ($script:avertizari.Count) {
    Write-Host ''
    Write-Host 'Atentie:' -ForegroundColor Red
    $script:avertizari | ForEach-Object { Write-Host "  - $_" }
    exit 2
}
exit 0
