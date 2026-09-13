[CmdletBinding()]
param([int]$GameProcessId)
$ErrorActionPreference = 'Stop'
$games = @(Get-Process -Name 'Warcraft III' -ErrorAction SilentlyContinue)
if ($GameProcessId) { $games = @($games | Where-Object Id -EQ $GameProcessId) }
if ($games.Count -ne 1) { throw 'Start WC3 with the capture build; specify -GameProcessId if multiple games are running.' }
$directory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CrashProtector'
if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'CrashProtector log directory does not exist.' }
$request = Join-Path $directory ('capture-' + $games[0].Id + '.request')
Set-Content -LiteralPath $request -Value 'manual'
Write-Output ('Capture requested. Check the log for wc3_capture_' + $games[0].Id + '_manual_*.exe; allow about 15 seconds. Keep WC3 open until the completion message.')
