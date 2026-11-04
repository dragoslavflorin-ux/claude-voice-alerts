# Reda un WAV in bucla (cu pauza) si arata o fereastra mica in coltul de jos, STANGA sau DREAPTA (-Pozitie),
# mereu deasupra, fara bordura, fara buton in taskbar, fara sa fure focusul. Click oriunde pe ea opreste vocea si o inchide.
# Se mai opreste la Esc, dupa MaxSeconds sau cand procesul e oprit din afara (fereastra moare cu el).
param(
    [Parameter(Mandatory = $true)][string]$Wav,
    [int]$MaxSeconds = 300,
    [int]$PauzaSec = 5,
    [string]$Mesaj = 'Claude Code',
    [ValidateSet('Stanga', 'Dreapta')][string]$Pozitie = 'Stanga',
    [string]$PidFile = 'claude-alerta.pid',
    [string]$Titlu = 'Claude Code',
    [int]$Margine = 16
)
$pidFile = Join-Path $env:TEMP $PidFile
Set-Content -Path $pidFile -Value $PID -Encoding ascii
try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if (-not ('AlertaForm' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class AlertaForm : Form {
    // nu fura focusul: nici la afisare, nici la click
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008; // NOACTIVATE | TOOLWINDOW | TOPMOST
            return cp;
        }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0021) { m.Result = (IntPtr)3; return; } // WM_MOUSEACTIVATE: raspunde MA_NOACTIVATE
        base.WndProc(ref m);
    }
}
public static class AlertaNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(System.Drawing.Point p, uint f);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr m, int t, out uint x, out uint y);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
}
'@
    }
    # DPI-aware inainte de orice fereastra, ca WorkingArea si pozitia sa fie in pixeli fizici
    if (-not [AlertaNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [void][AlertaNative]::SetProcessDPIAware() }
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $dpiX = [uint32]96; $dpiY = [uint32]96
    $mon = [AlertaNative]::MonitorFromPoint((New-Object System.Drawing.Point(0, 0)), 1)
    try { [void][AlertaNative]::GetDpiForMonitor($mon, 0, [ref]$dpiX, [ref]$dpiY) } catch { }
    $s = $dpiX / 96.0
    function Px([double]$v) { [int][Math]::Round($v * $s) }
    function FontPt([double]$pt, $style) { New-Object System.Drawing.Font('Segoe UI', [single]($pt * 96 / 72 * $s), $style, [System.Drawing.GraphicsUnit]::Pixel) }

    $player = New-Object System.Media.SoundPlayer $Wav
    $player.Load()
    # durata WAV-ului (PCM 16 bit mono 44.1 kHz, antet 44 octeti)
    $durMs = [int](((Get-Item $Wav).Length - 44) / (44100 * 2) * 1000)

    $bg = [System.Drawing.Color]::FromArgb(0, 14, 53)
    $f = New-Object AlertaForm
    $f.Text = $Titlu
    $f.AutoScaleMode = 'None'
    $f.FormBorderStyle = 'None'
    $f.ShowInTaskbar = $false
    $f.StartPosition = 'Manual'
    $f.BackColor = $bg
    $f.KeyPreview = $true
    $w = Px 300; $h = Px 118; $m = Px $Margine
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = if ($Pozitie -eq 'Dreapta') { $wa.Right - $w - $m } else { $wa.Left + $m }
    $f.Bounds = New-Object System.Drawing.Rectangle($x, ($wa.Bottom - $h - $m), $w, $h)

    $lblTitlu = New-Object System.Windows.Forms.Label
    $lblTitlu.Text = $Titlu
    $lblTitlu.ForeColor = [System.Drawing.Color]::FromArgb(150, 160, 190)
    $lblTitlu.BackColor = $bg
    $lblTitlu.Font = FontPt 9 ([System.Drawing.FontStyle]::Regular)
    $lblTitlu.AutoSize = $false
    $lblTitlu.SetBounds((Px 14), (Px 8), (Px 272), (Px 18))
    $f.Controls.Add($lblTitlu)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Mesaj
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(247, 245, 238)
    $lbl.BackColor = $bg
    $lbl.Font = FontPt 13 ([System.Drawing.FontStyle]::Bold)
    $lbl.AutoSize = $false
    $lbl.TextAlign = 'MiddleCenter'
    $lbl.SetBounds(0, (Px 28), $w, (Px 34))
    $f.Controls.Add($lbl)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = 'Opreste vocea'
    $btn.Font = FontPt 11 ([System.Drawing.FontStyle]::Bold)
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = [System.Drawing.Color]::FromArgb(255, 18, 0)
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.TabStop = $false
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.SetBounds((Px 60), (Px 68), (Px 180), (Px 38))
    $f.Controls.Add($btn)

    # click oriunde: opreste vocea si inchide
    $inchide = { $f.Close() }
    foreach ($c in @($f, $lblTitlu, $lbl, $btn)) { $c.Add_Click($inchide); $c.Cursor = [System.Windows.Forms.Cursors]::Hand }
    $f.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $f.Close() } })

    # colturi rotunjite (Windows 11) si chenar subtire
    $f.Add_HandleCreated({
        $v = 2; [void][AlertaNative]::DwmSetWindowAttribute($f.Handle, 33, [ref]$v, 4)
        $c = 0x00553A2A; [void][AlertaNative]::DwmSetWindowAttribute($f.Handle, 34, [ref]$c, 4)
    })

    $start = Get-Date
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = [Math]::Max(500, $durMs + $PauzaSec * 1000)
    $t.Add_Tick({
        if (((Get-Date) - $start).TotalSeconds + $PauzaSec -ge $MaxSeconds) { $f.Close() }
        else { $player.Play() }
    })
    $f.Add_Shown({ $player.Play(); $t.Start() })
    $f.Add_FormClosed({ $t.Stop(); $player.Stop() })
    [System.Windows.Forms.Application]::Run($f)
}
finally {
    # sterge fisierul doar daca e inca al nostru (o bucla noua l-a putut rescrie)
    $cur = (Get-Content -Path $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ("$cur".Trim() -eq "$PID") { Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue }
}
