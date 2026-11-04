# Dezinstaleaza alertele vocale: scoate exact ce a pus install.ps1 (hook-uri, fisiere, scurtatura, pornire automata).
# Rulare:  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
# Restul setarilor si al hook-urilor din ~/.claude ramane neatins. Backup-urile settings.json.bak-alerte-* raman.
$ErrorActionPreference = 'Continue'
$repo = $PSScriptRoot
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$hooks = Join-Path $claudeDir 'hooks'
$cwDir = Join-Path $hooks 'cowork'
$settings = Join-Path $claudeDir 'settings.json'
$manifest = Join-Path $hooks 'alerte-install.json'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
function Pas([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Info([string]$t) { Write-Host "   $t" }
$probleme = @()

$m = $null
if (Test-Path $manifest) { try { $m = Get-Content $manifest -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }

Pas 'Opresc alertele si watcher-ul'
$n = 0
foreach ($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue) {
    if ($p.CommandLine -like '*cowork-watch.ps1*' -or $p.CommandLine -like '*alerta-loop.ps1*') { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $n++ }
}
foreach ($f in 'claude-alerta.pid', 'claude-alerta-cowork.pid') { Remove-Item (Join-Path $env:TEMP $f) -Force -ErrorAction SilentlyContinue }
Info "procese oprite: $n"

Pas 'Scot hook-urile din ~/.claude/settings.json'
if (Test-Path $settings) {
    $py = $null
    foreach ($c in 'py', 'python', 'python3') { $g = Get-Command $c -ErrorAction SilentlyContinue; if ($g -and $g.Source -notlike '*\WindowsApps\*') { $py = $g.Source; break } }
    if (-not $py) { $py = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    if (-not $py) {
        $probleme += 'Python lipseste: scoate manual din settings.json hook-urile care contin alerta-start.ps1 / alerta-stop.ps1'
    }
    else {
        $bak = "$settings.bak-alerte-$stamp"
        Copy-Item $settings $bak -Force
        Info "backup: $bak"
        $r = & $py (Join-Path $repo 'instalare\setari_hooks.py') scoate $settings
        if ($LASTEXITCODE -eq 0) { Info "$r" } else { $probleme += "settings.json nu a putut fi modificat: $r" }
    }
}
else { Info 'settings.json nu exista' }

Pas 'Sterg fisierele'
$lista = @()
if ($m -and $m.fisiere) { $lista += @($m.fisiere) }
# lista fixa, pentru instalari fara manifest sau mai vechi
$lista += @('alerta-loop.ps1', 'alerta-stop.ps1', 'alerta-start.ps1', 'alerte-comun.ps1', 'verifica-alerte.ps1', 'alerte-config.json',
    'alerte-audio.json', 'alerte-install.json', 'claude-code-terminat.wav', 'claude-code-permisiune.wav',
    'm-am-terminat.mp3', 'm-am-terminat.wav', 'am-nevoie-de-tine.mp3', 'am-nevoie-de-tine.wav') | ForEach-Object { Join-Path $hooks $_ }
$lista += @('cowork-alerta.ps1', 'cowork-watch.ps1', 'cowork-watch-start.vbs', 'cowork-terminat.wav', 'cowork-permisiune.wav',
    'si-eu-m-am-terminat.mp3', 'si-eu-m-am-terminat.wav', 'si-eu-am-nevoie-de-tine.mp3', 'si-eu-am-nevoie-de-tine.wav',
    'watch.log', 'watch.log.1') | ForEach-Object { Join-Path $cwDir $_ }
$sterse = 0
foreach ($f in $lista | Select-Object -Unique) {
    # doar in ~/.claude/hooks, ca un manifest stricat sa nu poata sterge altceva
    if (-not $f.StartsWith($hooks, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (Test-Path -LiteralPath $f -PathType Leaf) { Remove-Item -LiteralPath $f -Force; $sterse++ }
}
if ((Test-Path $cwDir) -and -not (Get-ChildItem $cwDir -Force)) { Remove-Item $cwDir -Force; Info 'folderul cowork (gol) sters' }
Info "fisiere sterse: $sterse"

Pas 'Sterg scurtatura Ctrl+Alt+M si pornirea automata'
$lnk = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Opreste vocea Claude.lnk'), (Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Cowork watcher.lnk'))
if ($m) { if ($m.scurtatura) { $lnk += $m.scurtatura }; if ($m.pornire) { $lnk += $m.pornire } }
foreach ($l in $lnk | Select-Object -Unique) { if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force; Info "sters: $l" } }

Write-Host ''
if ($probleme.Count) {
    Write-Host 'Dezinstalare incompleta:' -ForegroundColor Red
    $probleme | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host 'Dezinstalare completa. Inchide si redeschide sesiunile Claude Code deschise.' -ForegroundColor Green
exit 0
