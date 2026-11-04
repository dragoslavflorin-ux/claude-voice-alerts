' Porneste watcher-ul Cowork complet ascuns (fara fereastra de consola).
Set sh = CreateObject("WScript.Shell")
d = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & d & "\cowork-watch.ps1""", 0, False
