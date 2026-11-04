# Removes claude-voice-alerts completely: hooks (only ours), install folder, skill, shortcuts, autostart, state.
# Also removes what v1 left behind. Everything else in ~/.claude stays as it is.
param([string]$Root)
$ErrorActionPreference = 'Continue'
$NAME = 'claude-voice-alerts'
if ($Root) {
    $Root = [IO.Path]::GetFullPath($Root)
    $claudeDir = Join-Path $Root '.claude'; $startMenu = Join-Path $Root 'StartMenu'; $startup = Join-Path $Root 'Startup'
    $desktop = Join-Path $Root 'Desktop'; $stateDir = Join-Path $Root 'state'
}
else {
    $claudeDir = Join-Path $env:USERPROFILE '.claude'; $startMenu = [Environment]::GetFolderPath('Programs')
    $startup = [Environment]::GetFolderPath('Startup'); $desktop = [Environment]::GetFolderPath('Desktop')
    $stateDir = Join-Path $env:TEMP $NAME
}
$hooksDir = Join-Path $claudeDir 'hooks'
$inst = Join-Path $hooksDir $NAME
$settings = Join-Path $claudeDir 'settings.json'
$problems = @()
function Step([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Info([string]$t) { Write-Host "   $t" }

Step 'Stopping alerts and the Cowork watcher'
$n = 0
foreach ($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue) {
    $cl = "$($p.CommandLine)"
    if ($p.ProcessId -eq $PID) { continue }
    if ($Root -and $cl -notlike "*$Root*") { continue }   # test mode: only processes of this test folder
    if ($cl -like '*cowork-watch.ps1*' -or $cl -like '*alerta-loop.ps1*' -or $cl -like "*$NAME*hub.ps1*") { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $n++ }
}
Info "processes stopped: $n"

Step 'Removing the hooks from settings.json'
if (Test-Path -LiteralPath $settings) {
    $py = $null
    foreach ($c in 'py', 'python', 'python3') { $g = Get-Command $c -ErrorAction SilentlyContinue; if ($g -and $g.Source -notlike '*\WindowsApps\*') { $py = $g.Source; break } }
    if (-not $py) { $py = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    $tool = Join-Path $PSScriptRoot 'settings_hooks.py'
    if (-not $py) { $problems += 'Python not found: remove by hand the hooks whose command contains claude-voice-alerts from settings.json' }
    else {
        $bak = "$settings.bak-cva-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $settings $bak -Force; Info "backup: $bak"
        $r = & $py -I $tool remove $settings
        if ($LASTEXITCODE -eq 0) { Info $r } else { $problems += "settings.json could not be changed: $r" }
    }
}

Step 'Removing shortcuts and autostart'
foreach ($l in @((Join-Path $startMenu 'Claude Voice Alerts'), (Join-Path $startup 'Claude Voice Alerts watcher.lnk'),
        (Join-Path $desktop 'Opreste vocea Claude.lnk'), (Join-Path $startup 'Claude Cowork watcher.lnk'))) {
    if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Recurse -Force; Info "removed: $l" }
}

Step 'Removing files'
# v1 leftovers
$v1 = @('alerta-loop.ps1', 'alerta-stop.ps1', 'alerta-start.ps1', 'alerte-comun.ps1', 'verifica-alerte.ps1', 'alerte-config.json',
    'alerte-audio.json', 'alerte-install.json', 'claude-code-terminat.wav', 'claude-code-permisiune.wav',
    'm-am-terminat.mp3', 'm-am-terminat.wav', 'am-nevoie-de-tine.mp3', 'am-nevoie-de-tine.wav',
    'cowork\cowork-alerta.ps1', 'cowork\cowork-watch.ps1', 'cowork\cowork-watch-start.vbs', 'cowork\cowork-terminat.wav',
    'cowork\cowork-permisiune.wav', 'cowork\si-eu-m-am-terminat.mp3', 'cowork\si-eu-m-am-terminat.wav',
    'cowork\si-eu-am-nevoie-de-tine.mp3', 'cowork\si-eu-am-nevoie-de-tine.wav', 'cowork\watch.log', 'cowork\watch.log.1')
foreach ($f in $v1) { $p = Join-Path $hooksDir $f; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
$cw = Join-Path $hooksDir 'cowork'; if ((Test-Path $cw) -and -not (Get-ChildItem $cw -Force)) { Remove-Item $cw -Force }
foreach ($d in @($inst, (Join-Path $claudeDir "skills\$NAME"), $stateDir)) {
    if ((Test-Path -LiteralPath $d) -and ($d -like "*$NAME*" -or $d -eq $stateDir)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue; Info "removed: $d" }
}
foreach ($d in @($inst, (Join-Path $claudeDir "skills\$NAME"))) { if (Test-Path -LiteralPath $d) { $problems += "could not remove $d (a file is in use; close it and run again)" } }

Write-Host ''
if ($problems.Count) { Write-Host 'Uninstall incomplete:' -ForegroundColor Red; $problems | ForEach-Object { Write-Host "  - $_" }; exit 1 }
Write-Host 'claude-voice-alerts removed. Backups of settings.json (settings.json.bak-cva-*) were kept.' -ForegroundColor Green
exit 0
