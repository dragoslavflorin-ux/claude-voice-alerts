# Health check in plain words: what works, what does not, and what to do about it.
param([string]$Root)
$ErrorActionPreference = 'Continue'
$NAME = 'claude-voice-alerts'
$claudeDir = if ($Root) { Join-Path ([IO.Path]::GetFullPath($Root)) '.claude' } else { Join-Path $env:USERPROFILE '.claude' }
$inst = Join-Path $claudeDir "hooks\$NAME"
$settings = Join-Path $claudeDir 'settings.json'
$script:problems = 0
function Good([string]$t) { Write-Host "  OK       $t" -ForegroundColor Green }
function Bad([string]$t, [string]$fix) { $script:problems++; Write-Host "  PROBLEM  $t" -ForegroundColor Red; if ($fix) { Write-Host "           What to do: $fix" -ForegroundColor Yellow } }
function Note([string]$t) { Write-Host "  INFO     $t" }

Write-Host "claude-voice-alerts doctor" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath (Join-Path $inst 'config.json'))) {
    Bad "not installed in $inst" 'run install.ps1 from the project folder'
    exit 1
}
$wd = Join-Path $inst 'platform\windows'
. (Join-Path $wd 'lib.ps1')
$cfg = Get-CvaConfig
$inf = Read-CvaJson (Join-Path $inst 'install.json')
Good "installed: version $($inf.version), language $($cfg.language), tone $($cfg.tone), parts: $(@($cfg.parts) -join ', ')"

# PowerShell can compile helper code (blocked in Constrained Language Mode / some company policies)
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { Bad "PowerShell runs in $($ExecutionContext.SessionState.LanguageMode); the alerts need FullLanguage" 'ask your IT department to allow PowerShell scripts for your user' }

# audio
foreach ($p in @($cfg.parts)) {
    foreach ($k in 'done', 'needs') {
        $f = Get-ChildItem (Join-Path $inst "audio\$p-$k.*") -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { Good "voice $p-$k ($($f.Name), $($f.Length) bytes)" } else { Bad "voice file $p-$k is missing" 'run install.ps1 again (it regenerates the voices)' }
    }
}

# Claude Code hooks
if (@($cfg.parts) -contains 'code') {
    $py = $null; foreach ($c in 'py', 'python') { $g = Get-Command $c -ErrorAction SilentlyContinue; if ($g -and $g.Source -notlike '*\WindowsApps\*') { $py = $g.Source; break } }
    if (-not (Test-Path -LiteralPath $settings)) { Bad 'settings.json not found' 'run install.ps1 again' }
    else {
        $raw = [IO.File]::ReadAllText($settings)
        $n = ([regex]::Matches($raw, [regex]::Escape($NAME))).Count
        if ($n -ge 5) { Good "Claude Code hooks present in settings.json ($n)" } else { Bad "Claude Code hooks missing or incomplete in settings.json ($n of 5)" 'run install.ps1 again' }
        if ($raw -match 'alerta-start\.ps1|alerta-stop\.ps1') { Bad 'old v1 hooks still present in settings.json' 'run install.ps1 again (it removes them)' }
        if ($raw -match 'fast\.sh') {
            $bash = Get-Command bash -ErrorAction SilentlyContinue
            if ($bash -or (Test-Path "$env:ProgramFiles\Git\bin\bash.exe")) { Good 'hooks use Git Bash (fast path, no PowerShell on every tool call)' }
            else { Bad 'hooks were installed for Git Bash, but Git Bash is not found' 'install Git for Windows, or run install.ps1 again to switch the hooks to PowerShell' }
        }
        else { Note 'hooks run in PowerShell (Git Bash was not found at install time): about 0.2 s per tool call' }
    }
}

# state, hub, pending alerts
$state = Get-CvaStateDir $cfg
try { $t = Join-Path $state 'alerts\doctor-test.tmp'; [IO.File]::WriteAllText($t, 'x'); Remove-Item $t; Good "state folder writable ($state)" } catch { Bad "cannot write to $state" 'check that your TEMP folder exists and is writable' }
$pending = @(Get-ChildItem -LiteralPath (Join-Path $state 'alerts') -Filter '*.json' -ErrorAction SilentlyContinue)
$hub = Test-CvaHubRunning
if ($pending.Count -and -not $hub) { Bad "$($pending.Count) alerts are waiting but the alert window is not running" 'run the hotkey shortcut once, or run install.ps1 again' }
elseif ($pending.Count) { Good "alert window running with $($pending.Count) alerts" }
else { Good 'no pending alerts (the alert window starts by itself when needed)' }

# hotkey shortcut
$inf2 = Read-CvaJson (Join-Path $inst 'install.json')
if ($inf2.stop_shortcut -and (Test-Path -LiteralPath $inf2.stop_shortcut)) {
    Initialize-CvaShortcut
    $hk = [CvaShortcut]::Hotkey($inf2.stop_shortcut)
    if ($hk -and $hk -eq (ConvertTo-CvaHotkey "$($cfg.hotkey)")) { Good "stop shortcut with hotkey $($cfg.hotkey)" } else { Bad 'stop shortcut has no hotkey, or not the one in config.json' 'run install.ps1 again' }
}
else { Bad 'stop shortcut is missing from the Start menu' 'run install.ps1 again' }

# Cowork
if (@($cfg.parts) -contains 'cowork') {
    $w = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*cowork-watch.ps1*' -and $_.CommandLine -notlike '*-Probe*' })
    if ($w.Count -eq 1) { Good "Cowork watcher running (pid $($w[0].ProcessId))" }
    elseif ($w.Count -gt 1) { Bad "$($w.Count) Cowork watchers are running" 'sign out and in again, or run install.ps1 again' }
    else { Bad 'Cowork watcher is not running' "start it with: & '$wd\launch-hidden.exe' cowork-watch.ps1   (it also starts at every logon)" }
    if ($inf2.startup -and (Test-Path -LiteralPath $inf2.startup)) { Good 'Cowork watcher starts at logon' } else { Bad 'Cowork watcher does not start at logon' 'run install.ps1 again' }
    $probe = $null
    try { $probe = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $wd 'cowork-watch.ps1') -Probe) | ConvertFrom-Json } catch { }
    if (-not $probe -or -not $probe.window) { Bad 'the Claude desktop app is not open (or only in the tray)' 'open the Claude app and leave its window open; it can stay behind other windows' }
    elseif (@($probe.rows).Count -eq 0) { Bad 'the Claude app is open, but its conversation list cannot be read' 'show the sidebar with your conversations; if the app language is not one of en, de, es, fr, it, ja, ko, pt-BR, hi, id, switch it to English' }
    else { Good "Claude app readable: $(@($probe.rows).Count) conversations, app language $($probe.language)" }
}

# recent log
$log = Join-Path $inst 'logs\alerts.log'
if (Test-Path -LiteralPath $log) {
    $lines = @(Get-Content -LiteralPath $log -Tail 12 -Encoding UTF8)
    $errs = @($lines | Where-Object { $_ -match 'error|fatal|missing' })
    if ($errs.Count) { Bad "recent errors in the log ($($errs.Count))" "read $log" }
    Write-Host ''; Write-Host '  Last events:'; $lines | ForEach-Object { Write-Host "    $_" }
}
else { Note 'no log yet (nothing happened since install)' }

Write-Host ''
if ($script:problems) { Write-Host "$script:problems problem(s) found." -ForegroundColor Red; exit 1 }
Write-Host 'Everything looks fine.' -ForegroundColor Green
exit 0
