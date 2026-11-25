<#
.SYNOPSIS
  Runs the title for a fixed time and prints one comparable result block.

.DESCRIPTION
  Starts `victory run <exe> --execute` with the given switches, stops it
  after -Seconds (or when it exits), then reads the log and prints a
  `victory-smoke v1` block: commit, switches, frames, frame time once the
  world is reached, dropped draws, peak commit, device removals, crashes,
  and hard page faults (sampled beside the run).

  For repeatable scenarios (snapshots, graphics presets, scripted input,
  thresholds) use scripts/harness.ps1; this is the quick one-off.

  Compare a change against main with the same -Seconds, -Env and input.
  The rule of thumb (from XCL): at least 80 % of main's frames, at most
  125 % of its peak commit, and no device removal.

  Works on Windows PowerShell 5.1.

.EXAMPLE
  .\scripts\smoke.ps1 -Seconds 600 -Env 'VICTORY_PROFILE=low;VICTORY_RELAY=2'
#>
param(
    [int]$Seconds = 300,
    # The title's executable; default: game_scarlett_master.exe in game_dir of victory.toml.
    [string]$Exe = '',
    [string]$Victory = '',
    # Switches for the run, 'NAME=value;NAME=value'.
    [string]$Env = '',
    [ValidateSet('series-x', 'series-s')]
    [string]$Console = 'series-x',
    [string]$Log = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\victory-run.ps1"
$paths = Get-VictoryPaths

if (-not $Victory) { $Victory = $paths.Victory }
$Victory = (Resolve-Path $Victory).Path
if (-not $Exe) {
    if (-not $paths.Game) { throw 'no -Exe and no game_dir in victory.toml' }
    $Exe = Join-Path $paths.Game 'game_scarlett_master.exe'
}
if (-not (Test-Path $Exe)) { throw "no title executable at $Exe" }
if (-not $Log) { $Log = Join-Path $script:RepoRoot ("smoke-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
if (-not [IO.Path]::IsPathRooted($Log)) { $Log = Join-Path (Get-Location) $Log }
$csv = [IO.Path]::ChangeExtension($Log, '.paging.csv')
$stop = [IO.Path]::ChangeExtension($Log, '.stop')
Remove-Item $stop -ErrorAction SilentlyContinue

$switches = @{}
foreach ($pair in ($Env -split ';' | Where-Object { $_ -match '=' })) {
    $name, $value = $pair -split '=', 2
    $switches[$name.Trim()] = $value.Trim()
}

$commit = (git -C $script:RepoRoot rev-parse --short HEAD) 2>$null
$dirty = if ((git -C $script:RepoRoot status --porcelain --untracked-files=no) 2>$null) { ' (uncommitted changes)' } else { '' }

$job = Start-PagingCounters -Csv $csv -StopFile $stop
try {
    $run = Invoke-VictoryRun -Victory $Victory -Exe $Exe -Log $Log -Seconds $Seconds -Env $switches -Console $Console
}
finally {
    New-Item -ItemType File $stop -Force | Out-Null
    Wait-Job $job -Timeout 10 | Out-Null
    Remove-Job $job -Force
    Remove-Item $stop -ErrorAction SilentlyContinue
}
$r = Read-VictoryLog -Log $Log -Csv $csv

$na = { param($v, $unit) if ($null -eq $v) { 'n/a' } else { "$v$unit" } }
$hard = 'n/a'
if ($r.HardFaults) { $hard = "median $($r.HardFaults.Median)/s, max $($r.HardFaults.Max)/s pages read from disk" }
$sw = ($switches.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '
if (-not $sw) { $sw = '(none)' }
$ranText = 'stopped'; if ($run.Exited) { $ranText = 'exited by itself' }

Write-Output @"
``````victory-smoke v1
commit       $commit$dirty
adapter      $($r.Adapter)
switches     $sw --console $Console
ran          $($run.Ran) s of $Seconds s ($ranText)
frames       $($r.FramesShown) shown; $($r.FrameLines) frame lines, $($r.WorldLines) in the world
world        median $(& $na $r.WorldMedianMs ' ms')/frame, median $(& $na $r.WorldMedianFps ' fps'), median $(& $na $r.WorldDropped '') draws dropped/frame, $(& $na $r.WorldMaking '') pipelines being made
peak commit  $($r.PeakCommitMB) MB
paging       $hard
removals     $($r.Removals) device removal line(s)
crashes      $($r.Crashes) unhandled exception line(s)
log          $Log
``````
"@
