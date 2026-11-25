<#
.SYNOPSIS
  Plays the title normally: no scripted presses, no time limit.

.DESCRIPTION
  Brings the shader and pipeline caches up to date (seconds when warm), then
  runs the title in a window with the switches the harness uses. Saves and
  settings go to their own folder (%LOCALAPPDATA%\victory\play), apart from
  the harness's, so playing never changes a test run's starting point.

  -Console series-s   1080p output (default; the usable rate on a 16 GB machine)
  -Console series-x   4K output
  -Full               all effects (no loop cap: slower)
  -NoPrepare          skip the cache step

  The log is written to play.log in the play folder.
#>
param(
    [ValidateSet('series-s', 'series-x')][string]$Console = 'series-s',
    [switch]$Full,
    [switch]$NoPrepare
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\victory-run.ps1"

$paths = Get-VictoryPaths
if (-not (Test-Path $paths.Victory)) { throw "no $($paths.Victory): build it first (cargo build --release -p victory)" }
if (-not $paths.Game) { throw 'no game_dir in victory.toml' }
if (Get-Process victory -ErrorAction SilentlyContinue) { throw 'victory.exe is already running' }

$play = Join-Path $env:LOCALAPPDATA 'victory\play'
New-Item -ItemType Directory -Force $play | Out-Null
$env:VICTORY_DATA_DIR = $play
$env:VICTORY_RELAY = '2'
$env:VICTORY_PIPELINE_WAIT_MS = '24'
if (-not $Full) { $env:VICTORY_PROFILE = 'low' }

if (-not $NoPrepare) {
    Write-Host 'preparing shader and pipeline caches...'
    & $paths.Victory precompile --pipelines | Select-Object -Last 2 | ForEach-Object { Write-Host "  $_" }
}

$exe = Join-Path $paths.Game 'game_scarlett_master.exe'
$log = Join-Path $play 'play.log'
Write-Host "playing as $Console; saves in $play; log in $log"
& $paths.Victory run $exe --execute --console $Console *> $log
