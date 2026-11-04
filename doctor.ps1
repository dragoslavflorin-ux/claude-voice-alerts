# claude-voice-alerts: health check in plain words.
& (Join-Path $PSScriptRoot 'platform\windows\doctor.ps1') @args
exit $LASTEXITCODE
