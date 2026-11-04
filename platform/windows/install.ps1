# claude-voice-alerts installer for Windows 10/11. Run through the install.ps1 wrapper in the project root.
# Interactive by default; every answer can be passed as a parameter (-Yes = no questions).
# Re-running uses the previous answers as defaults, upgrades older versions (including v1) and never duplicates hooks.
param(
    [string]$Language,
    [ValidateSet('', 'playful', 'neutral')][string]$Tone = '',
    [string]$CodeVoice,
    [string]$CoworkVoice,
    [string]$CodeDone,
    [string]$CodeNeedsYou,
    [string]$CoworkDone,
    [string]$CoworkNeedsYou,
    [ValidateSet('', 'both', 'code', 'cowork')][string]$Parts = '',
    [string]$Hotkey,
    [string]$CodeMonitor,
    [string]$CoworkMonitor,
    [string]$CodeCorner,
    [string]$CoworkCorner,
    [switch]$Yes,
    [switch]$NoPreview,
    [switch]$NoVerify,
    [switch]$NoStart,
    [string]$Root
)
$ErrorActionPreference = 'Continue'
$VERSION = '2.0.0'
$NAME = 'claude-voice-alerts'
$src = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$utf8 = New-Object System.Text.UTF8Encoding($false)
$env:PYTHONUTF8 = '1'

# ---------------------------------------------------------------- locations (all under -Root in test mode)
if ($Root) {
    $Root = [IO.Path]::GetFullPath($Root)
    $claudeDir = Join-Path $Root '.claude'; $startMenu = Join-Path $Root 'StartMenu'; $startup = Join-Path $Root 'Startup'
    $desktop = Join-Path $Root 'Desktop'; $stateDir = Join-Path $Root 'state'
}
else {
    $claudeDir = Join-Path $env:USERPROFILE '.claude'; $startMenu = [Environment]::GetFolderPath('Programs')
    $startup = [Environment]::GetFolderPath('Startup'); $desktop = [Environment]::GetFolderPath('Desktop')
    $stateDir = '%TEMP%\claude-voice-alerts'
}
$hooksDir = Join-Path $claudeDir 'hooks'
$inst = Join-Path $hooksDir $NAME
$settings = Join-Path $claudeDir 'settings.json'
$skillDir = Join-Path $claudeDir "skills\$NAME"
$menuDir = Join-Path $startMenu 'Claude Voice Alerts'
$stopLnk = Join-Path $menuDir 'Stop Claude voice alerts.lnk'
$startupLnk = Join-Path $startup 'Claude Voice Alerts watcher.lnk'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$warnings = New-Object System.Collections.Generic.List[string]

function Read-J([string]$p) { if (Test-Path -LiteralPath $p) { try { return ([IO.File]::ReadAllText($p, $utf8) | ConvertFrom-Json) } catch { } }; return $null }
function Step([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Info([string]$t) { Write-Host "   $t" }
function Warn([string]$t) { Write-Host "   ! $t" -ForegroundColor Yellow; $script:warnings.Add($t) }
function Fail([string]$t) { Write-Host "   ERROR: $t" -ForegroundColor Red; exit 1 }
$interactive = (-not $Yes) -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

function Ask-Choice([string]$Question, [string[]]$Options, [int]$Default) {
    if (-not $interactive) { return $Default }
    Write-Host ''; Write-Host $Question -ForegroundColor White
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ("  {0}. {1}{2}" -f ($i + 1), $Options[$i], $(if ($i -eq $Default) { '  <' } else { '' })) }
    while ($true) {
        $a = Read-Host "  $($T.choose) [$($Default + 1)]"
        if (-not $a) { return $Default }
        $n = 0; if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return ($n - 1) }
    }
}
function Ask-Text([string]$Label, [string]$Default) {
    if (-not $interactive) { return $Default }
    $a = Read-Host "  $Label [$Default]"
    if ($a) { return $a } else { return $Default }
}

# ---------------------------------------------------------------- previous answers
$prev = Read-J (Join-Path $inst 'config.json')
$langs = @('ro', 'en', 'es', 'pt', 'fr', 'de', 'it')
$locs = @{}; foreach ($l in $langs) { $locs[$l] = Read-J (Join-Path $src "locales\$l.json") }
$en = $locs['en']; $T = $en.installer

# a) language (asked in English)
$prevLang = if ($prev) { "$($prev.language)" } else { '' }
if (-not $Language) {
    $names = @($langs | ForEach-Object { $locs[$_].name }) + @('Other (any edge-tts voice, your own texts)')
    $def = if ($prevLang -in $langs) { [array]::IndexOf($langs, $prevLang) } elseif ($prevLang -eq 'other') { 7 } else { 1 }
    $k = Ask-Choice 'Language / Limba / Idioma / Langue / Sprache / Lingua' $names $def
    $Language = if ($k -eq 7) { 'other' } else { $langs[$k] }
}
if ($Language -ne 'other' -and $Language -notin $langs) { Fail "unknown language '$Language' (use one of: $($langs -join ', '), other)" }
$L = if ($Language -eq 'other') { $en } else { $locs[$Language] }
$T = $L.installer
foreach ($p in $en.installer.PSObject.Properties) { if (-not $T.($p.Name)) { $T | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force } }

# b) tone
if (-not $Tone) {
    $def = if ($prev -and $prev.tone -eq 'neutral') { 1 } else { 0 }
    $Tone = @('playful', 'neutral')[(Ask-Choice $T.q_tone @($T.tone_playful, $T.tone_neutral) $def)]
}

# c) voices
function Resolve-Voice([string]$Given, [string]$Question, [string]$Prev, [string]$DefaultGender) {
    if ($Given -in 'male', 'female') { if ($Language -eq 'other') { Fail '-CodeVoice/-CoworkVoice must be exact voice names when -Language other' }; return $L.voices.$Given }
    if ($Given) { return $Given }
    $opts = @("$($T.voice_male) ($($L.voices.male))", "$($T.voice_female) ($($L.voices.female))", $T.voice_custom)
    $def = if ($Prev -and $Prev -eq $L.voices.female) { 1 } elseif ($Prev -and $Prev -eq $L.voices.male) { 0 } elseif ($Prev) { 2 } elseif ($DefaultGender -eq 'female') { 1 } else { 0 }
    if ($Language -eq 'other') { return (Ask-Text "$Question. $($T.q_custom_voice)" $(if ($Prev) { $Prev } else { 'en-GB-RyanNeural' })) }
    $k = Ask-Choice $Question $opts $def
    if ($k -eq 0) { return $L.voices.male } elseif ($k -eq 1) { return $L.voices.female }
    return (Ask-Text $T.q_custom_voice $(if ($Prev) { $Prev } else { $L.voices.male }))
}
$prevSameLang = $prev -and "$($prev.language)" -eq $Language
$CodeVoice = Resolve-Voice $CodeVoice $T.q_code_voice $(if ($prevSameLang) { "$($prev.code.voice)" }) 'male'
$CoworkVoice = Resolve-Voice $CoworkVoice $T.q_cowork_voice $(if ($prevSameLang) { "$($prev.cowork.voice)" }) 'female'

# d) messages: empty = preset of the chosen tone
$preset = if ($Language -eq 'other') { $en.presets.$Tone } else { $L.presets.$Tone }
$msgs = [ordered]@{ code_done = $CodeDone; code_needs = $CodeNeedsYou; cowork_done = $CoworkDone; cowork_needs = $CoworkNeedsYou }
if ($interactive) { Write-Host ''; Write-Host $T.q_messages -ForegroundColor White }
foreach ($k in @($msgs.Keys)) {
    $part, $kind = $k -split '_'
    $prevCustom = if ($prevSameLang) { "$($prev.$part.$kind)" } else { '' }
    if (-not $msgs[$k]) {
        $shown = if ($prevCustom) { $prevCustom } else { "$($preset.$part.$kind)" }
        $a = Ask-Text $T."msg_$k" $shown
        $msgs[$k] = if ($a -eq "$($preset.$part.$kind)") { '' } else { $a }
    }
    if ($Language -eq 'other' -and -not $msgs[$k]) { $msgs[$k] = "$($preset.$part.$kind)" }
}

# e) parts
if (-not $Parts) {
    $def = 0
    if ($prev -and @($prev.parts).Count -eq 1) { $def = if (@($prev.parts)[0] -eq 'code') { 1 } else { 2 } }
    $Parts = @('both', 'code', 'cowork')[(Ask-Choice $T.q_parts @($T.parts_both, $T.parts_code, $T.parts_cowork) $def)]
}
$partList = switch ($Parts) { 'both' { @('code', 'cowork') } 'code' { @('code') } 'cowork' { @('cowork') } }
$code = $partList -contains 'code'; $cowork = $partList -contains 'cowork'

$def = Read-J (Join-Path $src 'config.default.json')
function Pick($a, $b, $c) { if ($a) { return $a } elseif ($b) { return $b } else { return $c } }
if (-not $Hotkey) { $Hotkey = Pick $(if ($prev) { "$($prev.hotkey)" }) '' "$($def.hotkey)" }

# ---------------------------------------------------------------- dependencies
Step $T.step_deps
function Find-Python {
    $cand = @()
    foreach ($c in 'py', 'python', 'python3') { $g = Get-Command $c -ErrorAction SilentlyContinue; if ($g) { $cand += $g.Source } }
    $cand += @(Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | ForEach-Object FullName)
    foreach ($c in $cand) {
        if ($c -like '*\WindowsApps\*') { continue }
        $v = & $c -c 'import sys; print(sys.version_info[0])' 2>$null
        if ("$v".Trim() -eq '3') { return $c }
    }
    return $null
}
$py = Find-Python
if (-not $py) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Fail 'Python 3 is missing and winget is not available. Install Python from python.org, then run the installer again.' }
    Info 'installing Python with winget...'
    & winget install -e --id Python.Python.3.12 --scope user --silent --accept-source-agreements --accept-package-agreements | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $py = Find-Python
    if (-not $py) { Fail 'Python could not be installed. Install it from python.org, then run the installer again.' }
}
Info "Python: $py"
& $py -m pip install --user --upgrade --quiet --disable-pip-version-check edge-tts 2>$null | Out-Null
$ttsOk = $false; & $py -m edge_tts --version 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $ttsOk = $true; Info 'edge-tts: OK (upgraded)' } else { Warn 'edge-tts could not be installed (pip install edge-tts)' }

# voices exist?
if ($ttsOk) {
    $list = (& $py -m edge_tts --list-voices 2>$null | Out-String)
    if ($list -match 'Neural') {
        foreach ($v in @(@('CodeVoice', $CodeVoice, $L.voices.male), @('CoworkVoice', $CoworkVoice, $L.voices.female))) {
            if ($list -notmatch "(?m)^$([regex]::Escape($v[1]))\s") {
                Warn "voice '$($v[1])' not found in edge-tts; using $($v[2])"
                Set-Variable -Name $v[0] -Value $v[2]
            }
        }
    }
}

# hotkey: does Ctrl+Alt+<key> type a character on this keyboard layout (AltGr)?
if (-not ('CvaKeys' -as [type])) {
    Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class CvaKeys {
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint t);
    [DllImport("user32.dll")] static extern int ToUnicodeEx(uint vk, uint sc, byte[] ks, StringBuilder b, int n, uint f, IntPtr hkl);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyEx(uint c, uint t, IntPtr hkl);
    public static string Typed(uint vk, bool ctrl, bool alt, bool shift) {
        var ks = new byte[256]; if (ctrl) { ks[0x11] = 0x80; ks[0xA2] = 0x80; } if (alt) { ks[0x12] = 0x80; ks[0xA5] = 0x80; } if (shift) ks[0x10] = 0x80;
        IntPtr hkl = GetKeyboardLayout(0); var b = new StringBuilder(8);
        int r = ToUnicodeEx(vk, MapVirtualKeyEx(vk, 0, hkl), ks, b, 8, 4, hkl);
        return r > 0 ? b.ToString(0, r) : "";
    }
}
'@
}
$keys = @("$Hotkey" -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$mods = @($keys | Select-Object -SkipLast 1 | ForEach-Object { $_.ToLower() })
$main = "$($keys[-1])".ToUpper()
if ($keys.Count -lt 2 -or $main -notmatch '^([A-Z0-9]|F([1-9]|1[0-9]|2[0-4]))$' -or @($mods | Where-Object { $_ -notin 'ctrl', 'control', 'alt', 'shift' }).Count) {
    Fail "invalid hotkey '$Hotkey' (examples: Ctrl+Alt+M, Ctrl+Shift+F12)"
}
if ($main.Length -eq 1) {
    $typed = [CvaKeys]::Typed([uint32][char]$main, ($mods -contains 'ctrl'), ($mods -contains 'alt'), ($mods -contains 'shift'))
    if ($typed -and [int][char]$typed[0] -ge 32) { Warn ($T.hotkey_conflict -replace '\{key\}', $Hotkey -replace '\{char\}', $typed) }
}

# ---------------------------------------------------------------- stop what runs (v1 and v2)
Step $T.step_stop
$killed = 0
foreach ($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue) {
    $cl = "$($p.CommandLine)"
    if ($p.ProcessId -eq $PID) { continue }
    if ($Root -and $cl -notlike "*$Root*") { continue }   # test mode: only processes of this test folder
    if ($cl -like '*cowork-watch.ps1*' -or $cl -like '*alerta-loop.ps1*' -or ($cl -like "*$NAME*hub.ps1*")) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $killed++ }
}
foreach ($n in 'claude-alerta.pid', 'claude-alerta-cowork.pid') { Remove-Item -LiteralPath (Join-Path $env:TEMP $n) -Force -ErrorAction SilentlyContinue }
Info "processes stopped: $killed"

# ---------------------------------------------------------------- files
Step $T.step_files
New-Item -ItemType Directory -Force -Path $inst | Out-Null
$same = ([IO.Path]::GetFullPath($src).TrimEnd('\') -ieq [IO.Path]::GetFullPath($inst).TrimEnd('\'))
if (-not $same) {
    foreach ($f in 'install.ps1', 'uninstall.ps1', 'doctor.ps1', 'config.default.json', 'SKILL.md', 'LICENSE', 'README.md') {
        if (Test-Path -LiteralPath (Join-Path $src $f)) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $inst $f) -Force }
    }
    foreach ($d in 'locales', 'platform\windows') {
        New-Item -ItemType Directory -Force -Path (Join-Path $inst $d) | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $src $d) -File | Where-Object { $_.Extension -ne '.exe' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $inst "$d\$($_.Name)") -Force }
    }
}
# bash must get LF line endings whatever git did on checkout
$fs = Join-Path $inst 'platform\windows\fast.sh'
[IO.File]::WriteAllText($fs, ([IO.File]::ReadAllText($fs) -replace "`r", ''), $utf8)

# v1 leftovers: scripts, audio, shortcuts (their hooks are replaced in settings.json below)
$v1 = @('alerta-loop.ps1', 'alerta-stop.ps1', 'alerta-start.ps1', 'alerte-comun.ps1', 'verifica-alerte.ps1', 'alerte-config.json',
    'alerte-audio.json', 'alerte-install.json', 'claude-code-terminat.wav', 'claude-code-permisiune.wav',
    'm-am-terminat.mp3', 'm-am-terminat.wav', 'am-nevoie-de-tine.mp3', 'am-nevoie-de-tine.wav',
    'cowork\cowork-alerta.ps1', 'cowork\cowork-watch.ps1', 'cowork\cowork-watch-start.vbs', 'cowork\cowork-terminat.wav',
    'cowork\cowork-permisiune.wav', 'cowork\si-eu-m-am-terminat.mp3', 'cowork\si-eu-m-am-terminat.wav',
    'cowork\si-eu-am-nevoie-de-tine.mp3', 'cowork\si-eu-am-nevoie-de-tine.wav', 'cowork\watch.log', 'cowork\watch.log.1')
$v1n = 0
foreach ($f in $v1) { $p = Join-Path $hooksDir $f; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; $v1n++ } }
$cwOld = Join-Path $hooksDir 'cowork'; if ((Test-Path $cwOld) -and -not (Get-ChildItem $cwOld -Force)) { Remove-Item $cwOld -Force }
foreach ($l in @((Join-Path $desktop 'Opreste vocea Claude.lnk'), (Join-Path $startup 'Claude Cowork watcher.lnk'))) { if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force; $v1n++ } }
if ($v1n) { Info "v1 files removed: $v1n" }

# launcher without VBScript
$exe = Join-Path $inst 'platform\windows\launch-hidden.exe'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$csSrc = Join-Path $inst 'platform\windows\launch-hidden.cs'
if (-not (Test-Path $exe) -or (Get-Item $csSrc).LastWriteTimeUtc -gt (Get-Item $exe).LastWriteTimeUtc) {
    & $csc /nologo /target:winexe /optimize "/out:$exe" $csSrc | Out-Null
    if (-not (Test-Path $exe)) { Fail 'could not build launch-hidden.exe (C# compiler of .NET Framework 4 not found)' }
}

# Cowork status labels straight from the installed Claude app (all its languages); bundled table is the fallback
$appExe = Get-Process claude -ErrorAction SilentlyContinue | Where-Object { "$($_.Path)" -like '*\WindowsApps\Claude_*' } | Select-Object -First 1 -ExpandProperty Path
if (-not $appExe) { $appExe = Get-ChildItem "$env:ProgramFiles\WindowsApps\Claude_*\app\claude.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName }
if ($appExe) {
    $asar = Join-Path (Split-Path $appExe) 'resources\ion-dist.asar'
    $tmpL = Join-Path $env:TEMP "cva-labels-$PID.json"
    $r = & $py -I (Join-Path $inst 'platform\windows\extract_labels.py') $asar $tmpL 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $tmpL)) { Move-Item $tmpL (Join-Path $inst 'platform\windows\cowork-labels.json') -Force; Info "Claude app labels: $r" }
    else { Remove-Item $tmpL -ErrorAction SilentlyContinue; Info 'Claude app labels: using the bundled table' }
}

# config
$cfg = [ordered]@{
    version = $VERSION; language = $Language; tone = $Tone; parts = @($partList)
    code = [ordered]@{ voice = $CodeVoice; done = $msgs.code_done; needs = $msgs.code_needs
        monitor = (Pick $CodeMonitor $(if ($prev) { "$($prev.code.monitor)" }) "$($def.code.monitor)")
        corner = (Pick $CodeCorner $(if ($prev) { "$($prev.code.corner)" }) "$($def.code.corner)") }
    cowork = [ordered]@{ voice = $CoworkVoice; done = $msgs.cowork_done; needs = $msgs.cowork_needs
        monitor = (Pick $CoworkMonitor $(if ($prev) { "$($prev.cowork.monitor)" }) "$($def.cowork.monitor)")
        corner = (Pick $CoworkCorner $(if ($prev) { "$($prev.cowork.corner)" }) "$($def.cowork.corner)") }
    hotkey = $Hotkey
    state_dir = $stateDir
}
foreach ($k in 'repeat_pause_seconds', 'voice_limit_seconds', 'keep_window_after_timeout', 'min_task_seconds', 'cowork_idle_seconds', 'max_rows', 'margin_px') {
    $cfg[$k] = if ($prev -and $null -ne $prev.$k) { $prev.$k } else { $def.$k }
}
[IO.File]::WriteAllText((Join-Path $inst 'config.json'), ([PSCustomObject]$cfg | ConvertTo-Json -Depth 5), $utf8)

# ---------------------------------------------------------------- audio
Step $T.step_audio
$audioDir = Join-Path $inst 'audio'; New-Item -ItemType Directory -Force -Path $audioDir | Out-Null
$stampF = Join-Path $audioDir 'audio.json'
$stamps = @{}; $o = Read-J $stampF; if ($o) { $o.PSObject.Properties | ForEach-Object { $stamps[$_.Name] = $_.Value } }
$generated = @()
foreach ($part in $partList) {
    foreach ($kind in 'done', 'needs') {
        $text = if ($cfg[$part][$kind]) { $cfg[$part][$kind] } else { "$($preset.$part.$kind)" }
        $voice = $cfg[$part].voice
        $aname = "$part-$kind"; $mp3 = Join-Path $audioDir "$aname.mp3"; $wav = Join-Path $audioDir "$aname.wav"
        $want = "$voice|$text"
        $generated += @{ name = $aname; text = $text; voice = $voice }
        if ($stamps[$aname] -eq $want -and ((Test-Path $mp3) -or (Test-Path $wav))) { Info "$aname unchanged"; continue }
        Remove-Item $mp3, $wav -Force -ErrorAction SilentlyContinue
        $txtF = Join-Path $env:TEMP "cva-text-$PID.txt"; [IO.File]::WriteAllText($txtF, $text, $utf8)
        if ($ttsOk) { & $py -m edge_tts --voice $voice --file $txtF --write-media $mp3 2>$null | Out-Null }
        Remove-Item $txtF -ErrorAction SilentlyContinue
        if (-not (Test-Path $mp3) -or (Get-Item $mp3).Length -lt 1000) {
            Remove-Item $mp3 -ErrorAction SilentlyContinue
            # fallback: a voice installed in Windows (SAPI), same language if possible
            Add-Type -AssemblyName System.Speech
            $syn = New-Object System.Speech.Synthesis.SpeechSynthesizer
            $culture = ($voice -split '-')[0..1] -join '-'
            $sv = $syn.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -eq $culture } | Select-Object -First 1
            if (-not $sv) { $sv = $syn.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.TwoLetterISOLanguageName -eq ($voice -split '-')[0] } | Select-Object -First 1 }
            if ($sv) { $syn.SelectVoice($sv.VoiceInfo.Name) }
            $syn.SetOutputToWaveFile($wav); $syn.Speak($text); $syn.SetOutputToNull(); $syn.Dispose()
            Warn ($T.tts_fallback -replace '\{voice\}', $(if ($sv) { $sv.VoiceInfo.Name } else { 'default' }))
            $want = "sapi|$text"
        }
        $stamps[$aname] = $want
        Info "$aname : '$text' ($voice)"
    }
}
[IO.File]::WriteAllText($stampF, ([PSCustomObject]$stamps | ConvertTo-Json), $utf8)

if (-not $NoPreview -and -not $Root) {
    Step $T.step_preview
    Add-Type -AssemblyName PresentationCore, WindowsBase, System.Windows.Forms
    $mp = New-Object System.Windows.Media.MediaPlayer
    foreach ($g in $generated) {
        $f = Get-ChildItem (Join-Path $audioDir "$($g.name).*") -Include *.mp3, *.wav | Select-Object -First 1
        if (-not $f) { continue }
        Write-Host "   >> $($g.text)   ($($g.voice))" -ForegroundColor Green
        $mp.Open([Uri]$f.FullName); $mp.Play()
        $ms = if ($f.Extension -eq '.mp3') { [int]($f.Length * 8 / 48) } else { 2500 }
        $t0 = Get-Date; while (((Get-Date) - $t0).TotalMilliseconds -lt ($ms + 400)) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
        $mp.Stop()
    }
    $mp.Close()
}

# ---------------------------------------------------------------- Claude Code hooks
if ($code) {
    Step $T.step_settings
    if (Test-Path -LiteralPath $settings) { Copy-Item -LiteralPath $settings "$settings.bak-cva-$stamp" -Force; Info "backup: $settings.bak-cva-$stamp" }
    $bash = $null
    if ($env:CLAUDE_CODE_GIT_BASH_PATH -and (Test-Path $env:CLAUDE_CODE_GIT_BASH_PATH)) { $bash = $env:CLAUDE_CODE_GIT_BASH_PATH }
    if (-not $bash) { $g = Get-Command git -ErrorAction SilentlyContinue; if ($g) { $c = Join-Path (Split-Path (Split-Path $g.Source)) 'bin\bash.exe'; if (Test-Path $c) { $bash = $c } } }
    if (-not $bash) { foreach ($c in "$env:ProgramFiles\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe") { if (Test-Path $c) { $bash = $c; break } } }
    $mode = if ($bash) { 'bash' } else { 'powershell' }
    $stateReal = [Environment]::ExpandEnvironmentVariables($stateDir)
    $r = & $py -I (Join-Path $inst 'platform\windows\settings_hooks.py') add $settings $inst $stateReal $mode
    if ($LASTEXITCODE -ne 0) { Fail "settings.json could not be updated (backup untouched): $r" }
    Info "$r (shell: $mode)"
    if ($mode -eq 'powershell') { Warn 'Git Bash not found: hooks run in PowerShell, so every tool call costs about 0.2 s more. Installing Git for Windows makes them instant.' }
}
else {
    if (Test-Path -LiteralPath $settings) { Copy-Item -LiteralPath $settings "$settings.bak-cva-$stamp" -Force; [void](& $py -I (Join-Path $inst 'platform\windows\settings_hooks.py') remove $settings) }
}

# skill for Claude Code
New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
Copy-Item -LiteralPath (Join-Path $inst 'SKILL.md') -Destination (Join-Path $skillDir 'SKILL.md') -Force

# ---------------------------------------------------------------- shortcuts
Step $T.step_shortcut
. (Join-Path $inst 'platform\windows\lib.ps1')
Initialize-CvaShortcut
New-Item -ItemType Directory -Force -Path $menuDir | Out-Null
try {
    [CvaShortcut]::Create($stopLnk, $exe, 'stop.ps1', (Split-Path $exe), (ConvertTo-CvaHotkey $Hotkey), 'Stop all Claude voice alerts', "$env:SystemRoot\System32\SHELL32.dll", 109)
    Info "$stopLnk ($Hotkey)"
} catch { Warn "could not create the stop shortcut: $($_.Exception.Message)" }
if ($cowork) {
    Step $T.step_startup
    New-Item -ItemType Directory -Force -Path (Split-Path $startupLnk) | Out-Null
    try { [CvaShortcut]::Create($startupLnk, $exe, 'cowork-watch.ps1', (Split-Path $exe), 0, 'Claude Voice Alerts: Cowork watcher', '', 0); Info $startupLnk }
    catch { Warn "could not create the autostart shortcut: $($_.Exception.Message)" }
}
elseif (Test-Path -LiteralPath $startupLnk) { Remove-Item -LiteralPath $startupLnk -Force }

[IO.File]::WriteAllText((Join-Path $inst 'install.json'), ([PSCustomObject]@{ version = $VERSION; installed = (Get-Date -Format 's'); source = $src; stop_shortcut = $stopLnk; startup = $(if ($cowork) { $startupLnk }); skill = $skillDir } | ConvertTo-Json), $utf8)

# ---------------------------------------------------------------- start and verify
$appLine = $null
if ($cowork -and -not $NoStart) {
    Start-Process -FilePath $exe -ArgumentList 'cowork-watch.ps1'
    $probe = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $inst 'platform\windows\cowork-watch.ps1') -Probe | ConvertFrom-Json
    $appLine = if ($probe -and @($probe.rows).Count -gt 0 -and $probe.language) { $T.app_lang_ok -replace '\{lang\}', $probe.language } else { $T.app_lang_bad }
    if ($appLine -eq $T.app_lang_bad) { $warnings.Add($T.app_lang_bad) }
}
$verifyOk = $null
if (-not $NoVerify -and -not $Root) {
    Step $T.step_verify
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $inst 'platform\windows\verify.ps1') | ForEach-Object { Write-Host "   $_" }
    $verifyOk = ($LASTEXITCODE -eq 0)
    if (-not $verifyOk) { $warnings.Add('verify.ps1 found problems (see above)') }
}

# ---------------------------------------------------------------- summary
Write-Host ''
Write-Host "================ $($T.summary) ================" -ForegroundColor Green
Write-Host "$NAME $VERSION : $inst"
foreach ($g in $generated) { Write-Host ("  {0,-13} {1}  ({2})" -f $g.name, $g.text, $g.voice) }
Write-Host "  $($T.hotkey_ok -replace '\{key\}', $Hotkey)"
if ($appLine) { Write-Host "  $appLine" }
Write-Host ''
Write-Host "$($T.manual):" -ForegroundColor Yellow
if ($code) { Write-Host "  - $($T.manual_code)" }
if ($cowork) { Write-Host "  - $($T.manual_cowork_1)"; Write-Host "  - $($T.manual_cowork_2)" }
Write-Host ''
if ($warnings.Count) { Write-Host $T.done_warn -ForegroundColor Yellow; $warnings | ForEach-Object { Write-Host "  - $_" }; exit 2 }
Write-Host $T.done_ok -ForegroundColor Green
exit 0
