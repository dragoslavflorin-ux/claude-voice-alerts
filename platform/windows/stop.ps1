# Stops alerts: removes the alert files; the hub sees an empty list, goes silent and exits.
# Used by the hotkey shortcut (all parts). -Part code|cowork stops only one part.
param([ValidateSet('all', 'code', 'cowork')][string]$Part = 'all')
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib.ps1')
$dir = Join-Path (Get-CvaStateDir (Get-CvaConfig)) 'alerts'
$filter = if ($Part -eq 'all') { '*.json' } else { "$Part-*.json" }
$n = 0
foreach ($f in Get-ChildItem -LiteralPath $dir -Filter $filter -File) { Remove-Item -LiteralPath $f.FullName -Force; $n++ }
Write-CvaLog 'stop' "stop $Part ($n alerts)"
exit 0
