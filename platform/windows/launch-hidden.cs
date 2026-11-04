// Starts a PowerShell script with no console window at all (replaces the old VBScript launcher).
// Usage: launch-hidden.exe <script.ps1 relative to this exe or absolute> [arguments...]
// Compiled by install.ps1 with the C# compiler that ships with Windows (.NET Framework 4).
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

static class LaunchHidden
{
    static int Main(string[] args)
    {
        if (args.Length < 1) return 1;
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.IsPathRooted(args[0]) ? args[0] : Path.Combine(dir, args[0]);
        var sb = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"");
        for (int i = 1; i < args.Length; i++) sb.Append(" \"").Append(args[i].Replace("\"", "\\\"")).Append('"');
        string ps = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        var psi = new ProcessStartInfo(ps, sb.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
        return 0;
    }
}
