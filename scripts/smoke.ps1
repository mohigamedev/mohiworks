<#
.SYNOPSIS
  Runs the title for a fixed time and prints one comparable result block.

.DESCRIPTION
  Starts `victory run <exe> --execute` with the given switches, stops it
  after -Seconds (or when it exits), then reads the log and prints a
  `victory-smoke v1` block: commit, switches, frames, frame time once the
  world is reached, dropped draws, peak commit, device removals, crashes.

  Compare a change against main with the same -Seconds, -Env and input.
  The rule of thumb this follows (from XCL): at least 80 % of main's frames,
  at most 125 % of its peak commit, and no device removal.

  Works on Windows PowerShell 5.1.

.EXAMPLE
  .\scripts\smoke.ps1 -Seconds 600 -Env 'VICTORY_PROFILE=low;VICTORY_RELAY=2'
#>
param(
    [int]$Seconds = 300,
    # The title's executable; default: game_scarlett_master.exe in game_dir of victory.toml.
    [string]$Exe = '',
    [string]$Victory = "$PSScriptRoot\..\target\release\victory.exe",
    # Switches for the run, 'NAME=value;NAME=value'.
    [string]$Env = '',
    [ValidateSet('series-x', 'series-s')]
    [string]$Console = 'series-x',
    [string]$Log = ''
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\.."

if (-not $Exe) {
    $toml = Join-Path $root 'victory.toml'
    if (-not (Test-Path $toml)) { throw 'no -Exe and no victory.toml' }
    $line = Select-String -Path $toml -Pattern "^\s*game_dir\s*=\s*'([^']+)'" | Select-Object -First 1
    if (-not $line) { throw 'no game_dir in victory.toml' }
    $Exe = Join-Path $line.Matches[0].Groups[1].Value 'game_scarlett_master.exe'
}
if (-not $Log) { $Log = Join-Path $root ("smoke-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
if (-not [IO.Path]::IsPathRooted($Log)) { $Log = Join-Path (Get-Location) $Log }
$Victory = (Resolve-Path $Victory).Path
if (-not (Test-Path $Exe)) { throw "no title executable at $Exe" }

# The switches go into this process's environment, which the run inherits.
$switches = @()
foreach ($pair in ($Env -split ';' | Where-Object { $_ -match '=' })) {
    $name, $value = $pair -split '=', 2
    [Environment]::SetEnvironmentVariable($name.Trim(), $value.Trim(), 'Process')
    $switches += "$($name.Trim())=$($value.Trim())"
}

$commit = (git -C $root rev-parse --short HEAD) 2>$null
$dirty = if ((git -C $root status --porcelain --untracked-files=no) 2>$null) { ' (uncommitted changes)' } else { '' }

$started = Get-Date
$cmdline = "`"$Victory`" run `"$Exe`" --execute --console $Console > `"$Log`" 2>&1"
# cmd /c strips the outer quotes of a line with several quoted parts: one
# more pair around the whole line keeps the inner ones.
$proc = Start-Process -FilePath cmd.exe -ArgumentList '/c', "`"$cmdline`"" -PassThru -WindowStyle Hidden
$exited = $proc.WaitForExit($Seconds * 1000)
if (-not $exited) {
    Get-Process victory -ErrorAction SilentlyContinue | Stop-Process -Force
    $proc.WaitForExit(10000) | Out-Null
}
$ran = [int]((Get-Date) - $started).TotalSeconds

# Read the log without its colour codes.
$text = (Get-Content $Log -Raw -ErrorAction SilentlyContinue) -replace "$([char]27)\[[0-9;]*m", ''
if (-not $text) { $text = '' }
$lines = $text -split "`r?`n"

$frames = @()
foreach ($l in $lines) {
    if ($l -match '([\d.]+) fps, ([\d.]+) ms/frame .*?, ([\d.]+) draws/frame, dropped ([\d.]+) without') {
        $frames += [pscustomobject]@{
            Fps = [double]$Matches[1]; Ms = [double]$Matches[2]
            Draws = [double]$Matches[3]; Dropped = [double]$Matches[4]
        }
    }
}
# The world: frame lines with more than 300 draws (menus have under 50).
$world = @($frames | Where-Object { $_.Draws -gt 300 })
function Median($values) {
    $s = @($values | Sort-Object)
    if ($s.Count -eq 0) { return 'n/a' }
    return [math]::Round($s[[int]($s.Count / 2)], 1)
}
# Frames shown: fps x the 5 s each frame line covers, summed.
$shown = [int](($frames | Measure-Object -Property Fps -Sum).Sum * 5)
$peak = 0
foreach ($l in $lines) {
    if ($l -match 'memory: \d+ MB committed \(peak (\d+) MB\)') { $peak = [math]::Max($peak, [int]$Matches[1]) }
}
$removed = @($lines | Where-Object { $_ -match 'device removed' }).Count
$crashes = @($lines | Where-Object { $_ -match 'unhandled exception' }).Count
$adapter = ($lines | Where-Object { $_ -match 'host adapter' } | Select-Object -First 1) -replace '.*adapter=', ''

$block = @"
``````victory-smoke v1
commit       $commit$dirty
adapter      $adapter
switches     $(if ($switches) { $switches -join ' ' } else { '(none)' }) --console $Console
ran          $ran s of $Seconds s ($(if ($exited) { 'exited by itself' } else { 'stopped' }))
frames       $shown shown; $($frames.Count) frame lines, $($world.Count) in the world
world        median $(Median ($world | ForEach-Object { $_.Ms })) ms/frame, median $(Median ($world | ForEach-Object { $_.Fps })) fps, median $(Median ($world | ForEach-Object { $_.Dropped })) draws dropped/frame
peak commit  $peak MB
removals     $removed device removal line(s)
crashes      $crashes unhandled exception line(s)
log          $Log
``````
"@
Write-Output $block
