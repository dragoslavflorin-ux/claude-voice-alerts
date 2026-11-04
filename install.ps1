# claude-voice-alerts: installer. Windows 10/11 only for now; the code lives in platform\windows.
#   powershell -ExecutionPolicy Bypass -File .\install.ps1            (asks 5 questions)
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Yes ...   (no questions, see README)
& (Join-Path $PSScriptRoot 'platform\windows\install.ps1') @args
exit $LASTEXITCODE
