# claude-voice-alerts: removes everything the installer added (and what v1 left behind).
& (Join-Path $PSScriptRoot 'platform\windows\uninstall.ps1') @args
exit $LASTEXITCODE
