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
    # The cache step's whole output (warnings too) goes to precompile.log;
    # its "n/total" lines drive a progress bar, its summary lines are shown.
    $prepLog = Join-Path $play 'precompile.log'
    Write-Host "preparing shader and pipeline caches (log: $prepLog)"
    $step = 'Shaders'
    $started = Get-Date
    & $paths.Victory precompile --pipelines 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $prepLog | ForEach-Object {
        if ($_ -match '^translating\s') { $step = 'Shaders' }
        elseif ($_ -match '^replaying\s') { $step = 'Pipelines' }
        if ($_ -match '^\s+(\d+)/(\d+)\s+\((.*)\)') {
            $n = [int]$Matches[1]; $total = [math]::Max(1, [int]$Matches[2])
            $pct = [int](100 * $n / $total)
            Write-Progress -Activity "Preparing caches: $step" -Status "$n of $total ($($Matches[3]))" -PercentComplete $pct
        } elseif ($_ -match '^done\s') {
            Write-Host "  $_"
            $started = Get-Date
        }
    }
    Write-Progress -Activity 'Preparing caches' -Completed
    $failed = @(Select-String -Path $prepLog -Pattern '^\s+\d+\s{2}\S' | Select-Object -First 5)
    if ($failed) {
        Write-Host '  shaders that do not translate yet, by reason (draws using them are dropped):'
        $failed | ForEach-Object { Write-Host "  $($_.Line)" }
    }
}

$exe = Join-Path $paths.Game 'game_scarlett_master.exe'
$log = Join-Path $play 'play.log'
Write-Host "playing as $Console; saves in $play; log in $log"
& $paths.Victory run $exe --execute --console $Console *> $log
