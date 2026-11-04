# Shared helpers for claude-voice-alerts (Windows). Dot-source this file.
# All text files are UTF-8. This file must stay ASCII (Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI).

$script:CvaRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Read-CvaJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return ([IO.File]::ReadAllText($Path, $script:Utf8) | ConvertFrom-Json) } catch { return $null }
}

function Write-CvaJson([string]$Path, $Object, [int]$Depth = 8) {
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth $Depth), $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Deep merge: values from $Over replace values in $Base (PSCustomObject trees).
function Merge-CvaObject($Base, $Over) {
    if ($null -eq $Over) { return $Base }
    if ($null -eq $Base -or $Base -isnot [PSCustomObject] -or $Over -isnot [PSCustomObject]) { return $Over }
    $r = [ordered]@{}
    foreach ($p in $Base.PSObject.Properties) { $r[$p.Name] = $p.Value }
    foreach ($p in $Over.PSObject.Properties) {
        if ($r.Contains($p.Name)) { $r[$p.Name] = Merge-CvaObject $r[$p.Name] $p.Value } else { $r[$p.Name] = $p.Value }
    }
    return [PSCustomObject]$r
}

function Get-CvaConfig {
    $def = Read-CvaJson (Join-Path $script:CvaRoot 'config.default.json')
    $usr = Read-CvaJson (Join-Path $script:CvaRoot 'config.json')
    return (Merge-CvaObject $def $usr)
}

function Get-CvaLocale([string]$Language) {
    $en = Read-CvaJson (Join-Path $script:CvaRoot 'locales\en.json')
    if (-not $Language -or $Language -eq 'en') { return $en }
    $loc = Read-CvaJson (Join-Path $script:CvaRoot "locales\$Language.json")
    return (Merge-CvaObject $en $loc)
}

function Get-CvaStateDir($Config) {
    $d = if ($Config -and $Config.state_dir) { [Environment]::ExpandEnvironmentVariables("$($Config.state_dir)") } else { Join-Path $env:TEMP 'claude-voice-alerts' }
    foreach ($s in 'alerts', 'start') { $p = Join-Path $d $s; if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }
    return $d
}

function Write-CvaLog([string]$Source, [string]$Message) {
    try {
        $dir = Join-Path $script:CvaRoot 'logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $f = Join-Path $dir 'alerts.log'
        if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 1MB) { Move-Item -LiteralPath $f "$f.1" -Force }
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Source] $Message`r`n"
        [IO.File]::AppendAllText($f, $line, (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}

function Get-CvaUnixMs { [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }

function Test-CvaHubRunning {
    $m = $null
    if ([System.Threading.Mutex]::TryOpenExisting('Local\ClaudeVoiceAlertsHub', [ref]$m)) { $m.Dispose(); return $true }
    return $false
}

function Start-CvaHub {
    if (Test-CvaHubRunning) { return }
    $hub = Join-Path $PSScriptRoot 'hub.ps1'
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$hub`"") | Out-Null
}

# One alert = one JSON file in <state>\alerts. Hooks and the Cowork watcher add/remove files; the hub shows them.
function Add-CvaAlert($Config, [string]$Part, [string]$Id, [string]$Kind, [string]$Project, [hashtable]$Extra) {
    $state = Get-CvaStateDir $Config
    $safe = ($Id -replace '[^A-Za-z0-9_.-]', '_')
    $e = [ordered]@{ part = $Part; id = $Id; kind = $Kind; project = $Project; created = (Get-CvaUnixMs) }
    if ($Extra) { foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] } }
    Write-CvaJson (Join-Path $state "alerts\$Part-$safe.json") ([PSCustomObject]$e)
    Start-CvaHub
}

function Remove-CvaAlert($Config, [string]$Part, [string]$Id) {
    $state = Get-CvaStateDir $Config
    $safe = ($Id -replace '[^A-Za-z0-9_.-]', '_')
    $f = Join-Path $state "alerts\$Part-$safe.json"
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; return $true }
    return $false
}

function Get-CvaHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $b = $sha.ComputeHash($script:Utf8.GetBytes($Text))
    return (($b[0..7] | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ---------------------------------------------------------------- shortcuts (IShellLinkW: works with any Unicode path)
function Initialize-CvaShortcut {
    if ('CvaShortcut' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices; using System.Runtime.InteropServices.ComTypes;
[ComImport, Guid("00021401-0000-0000-C000-000000000046")] class CvaShellLink { }
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
interface ICvaShellLinkW {
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder f, int cch, IntPtr pfd, uint fl);
    void GetIDList(out IntPtr p); void SetIDList(IntPtr p);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder n, int cch);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string n);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder d, int cch);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string d);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder a, int cch);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string a);
    void GetHotkey(out ushort w); void SetHotkey(ushort w);
    void GetShowCmd(out int c); void SetShowCmd(int c);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder p, int cch, out int i);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string p, int i);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string p, uint r);
    void Resolve(IntPtr h, uint f);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string f);
}
public static class CvaShortcut {
    public static void Create(string lnk, string target, string args, string dir, ushort hotkey, string desc, string icon, int iconIndex) {
        var l = (ICvaShellLinkW)new CvaShellLink();
        l.SetPath(target); l.SetArguments(args ?? ""); l.SetWorkingDirectory(dir ?? ""); l.SetDescription(desc ?? "");
        if (hotkey != 0) l.SetHotkey(hotkey);
        if (!String.IsNullOrEmpty(icon)) l.SetIconLocation(icon, iconIndex);
        ((IPersistFile)l).Save(lnk, true);
    }
    public static ushort Hotkey(string lnk) {
        var l = (ICvaShellLinkW)new CvaShellLink(); ((IPersistFile)l).Load(lnk, 0); ushort w; l.GetHotkey(out w); return w;
    }
}
"@
}

# "Ctrl+Alt+M" to IShellLink hotkey word (low byte: virtual key, high byte: 1 Shift, 2 Ctrl, 4 Alt). 0 if invalid.
function ConvertTo-CvaHotkey([string]$Text) {
    $keys = @("$Text" -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($keys.Count -lt 2) { return 0 }
    $mod = 0
    foreach ($m in $keys[0..($keys.Count - 2)]) { switch -Regex ($m) { '^(ctrl|control)$' { $mod = $mod -bor 2 } '^alt$' { $mod = $mod -bor 4 } '^shift$' { $mod = $mod -bor 1 } default { return 0 } } }
    $k = "$($keys[-1])".ToUpper()
    if ($k -match '^[A-Z0-9]$') { $vk = [int][char]$k } elseif ($k -match '^F([1-9]|1[0-9]|2[0-4])$') { $vk = 0x6F + [int]$Matches[1] } else { return 0 }
    return [uint16](($mod -shl 8) -bor $vk)
}