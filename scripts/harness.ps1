<#
.SYNOPSIS
  The test harness: runs the title in repeatable scenarios and records results.

.DESCRIPTION
  A scenario (scenarios/<name>.json in the repo) names:
    seconds     how long to run
    console     series-x | series-s (default series-x)
    snapshot    a saved data folder to start from (optional)
    preset      a graphics preset to write into the title's settings (optional)
    keys        scripted input, VICTORY_KEYS form: "20:Enter,26:Enter" (optional)
    env         VICTORY_* switches, an object of NAME: value (optional)
    pass        thresholds: min_frames, reach_world, max_world_median_ms,
                max_peak_commit_mb, max_removals (default 0), max_crashes (default 0)

  Everything taken from the user's own game stays outside the repository
  (docs/asset-policy.md), under %LOCALAPPDATA%\victory\harness:
    presets\<name>.json    graphics presets: { "<setting path>": "<value>" }
                           where a path is an element of the title's
                           settings file, nested with '/' (e.g. "a/b")
    snapshots\<name>\      copies of the title's data folder (saves, settings)
    backup\                the data folder as it was before the last run
    results\<time>-<scenario>\   run.log, paging.csv, result.json

  Before a run the title's data folder is backed up; with a snapshot it is
  replaced by the snapshot; a preset is then written into its settings.
  After the run the backup is put back, so a run never changes the user's
  own saves or settings (-Keep leaves the run's state instead).

.EXAMPLE
  .\scripts\harness.ps1 list
  .\scripts\harness.ps1 snapshot world          # after saving in the world
  .\scripts\harness.ps1 run world-continue
  .\scripts\harness.ps1 run-all
#>
param(
    [Parameter(Position = 0)][ValidateSet('list', 'run', 'run-all', 'snapshot', 'restore', 'record')]
    [string]$Command = 'list',
    [Parameter(Position = 1)][string]$Name = '',
    [switch]$Keep,
    # record: start from this snapshot / preset, with these switches
    # ('NAME=value;NAME=value'), for at most this long.
    [string]$Snapshot = '',
    [string]$Preset = '',
    [string]$Env = '',
    [int]$Seconds = 1800,
    # record: also save the data folder as this snapshot when the title closes.
    [string]$SnapshotAs = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\victory-run.ps1"

$paths = Get-VictoryPaths
$scenarioDir = Join-Path $script:RepoRoot 'scenarios'
foreach ($d in 'presets', 'snapshots', 'backup', 'results') {
    New-Item -ItemType Directory -Force (Join-Path $paths.Harness $d) | Out-Null
}

# The title's own data folder: the one folder under the data root.
function Get-TitleData {
    $dirs = @(Get-ChildItem $paths.Data -Directory -ErrorAction SilentlyContinue)
    if ($dirs.Count -ne 1) { throw "expected one title folder in $($paths.Data), found $($dirs.Count) (run the title once first)" }
    return $dirs[0].FullName
}

function Copy-Folder([string]$From, [string]$To) {
    if (Test-Path $To) { Remove-Item -Recurse -Force $To }
    Copy-Item -Recurse $From $To
}

# Writes a preset into the title's settings file (XML), element by element.
function Set-Preset([string]$TitleData, [string]$Preset) {
    $file = Join-Path $paths.Harness "presets\$Preset.json"
    if (-not (Test-Path $file)) { throw "no preset $file" }
    $settings = Get-ChildItem $TitleData -Recurse -Filter 'settings.xml' | Select-Object -First 1
    if (-not $settings) { throw "no settings file under $TitleData (run the title once first)" }
    [xml]$xml = Get-Content $settings.FullName -Raw
    $values = Get-Content $file -Raw | ConvertFrom-Json
    $changed = 0
    foreach ($p in $values.PSObject.Properties) {
        $xpath = '//' + (($p.Name -split '/') -join '/')
        $node = $xml.SelectSingleNode($xpath)
        if (-not $node) { Write-Warning "preset ${Preset}: no setting $($p.Name)"; continue }
        $node.SetAttribute('value', [string]$p.Value)
        $changed++
    }
    $xml.Save($settings.FullName)
    Write-Host "preset         $Preset ($changed settings written)"
}

function Test-Pass($r, $pass) {
    $fails = @()
    if (-not $pass) { $pass = [pscustomobject]@{} }
    $maxRemovals = 0; if ($null -ne $pass.max_removals) { $maxRemovals = $pass.max_removals }
    $maxCrashes = 0; if ($null -ne $pass.max_crashes) { $maxCrashes = $pass.max_crashes }
    if ($r.Removals -gt $maxRemovals) { $fails += "device removals $($r.Removals) > $maxRemovals" }
    if ($r.Crashes -gt $maxCrashes) { $fails += "crashes $($r.Crashes) > $maxCrashes" }
    if ($pass.min_frames -and $r.FramesShown -lt $pass.min_frames) { $fails += "frames $($r.FramesShown) < $($pass.min_frames)" }
    if ($pass.reach_world -and -not $r.ReachedWorld) { $fails += 'did not reach the world' }
    if ($pass.max_world_median_ms -and $r.ReachedWorld -and $r.WorldMedianMs -gt $pass.max_world_median_ms) {
        $fails += "world median $($r.WorldMedianMs) ms > $($pass.max_world_median_ms)"
    }
    if ($pass.max_peak_commit_mb -and $r.PeakCommitMB -gt $pass.max_peak_commit_mb) {
        $fails += "peak commit $($r.PeakCommitMB) MB > $($pass.max_peak_commit_mb)"
    }
    return , $fails
}

function Invoke-Scenario([string]$ScenarioName, $Given = $null) {
    $s = $Given
    if (-not $s) {
        $file = Join-Path $scenarioDir "$ScenarioName.json"
        if (-not (Test-Path $file)) { throw "no scenario $file" }
        $s = Get-Content $file -Raw | ConvertFrom-Json
    }
    if (-not (Test-Path $paths.Victory)) { throw "no $($paths.Victory): build it first (ninja)" }
    if (-not $paths.Game) { throw 'no game_dir in victory.toml' }
    $exe = Join-Path $paths.Game 'game_scarlett_master.exe'
    $console = 'series-x'; if ($s.console) { $console = $s.console }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $out = Join-Path $paths.Harness "results\$stamp-$ScenarioName"
    New-Item -ItemType Directory -Force $out | Out-Null
    Write-Host "scenario       $ScenarioName -> $out"

    $title = Get-TitleData
    $backup = Join-Path $paths.Harness 'backup\data'
    Copy-Folder $title $backup
    $envs = @{}
    try {
        if ($s.snapshot) {
            $snap = Join-Path $paths.Harness "snapshots\$($s.snapshot)"
            if (-not (Test-Path $snap)) { throw "no snapshot '$($s.snapshot)': make it with 'harness.ps1 snapshot $($s.snapshot)'" }
            Copy-Folder $snap $title
            Write-Host "snapshot       $($s.snapshot)"
        }
        if ($s.preset) { Set-Preset $title $s.preset }
        if ($s.env) { foreach ($p in $s.env.PSObject.Properties) { $envs[$p.Name] = [string]$p.Value } }
        if ($s.keys) { $envs['VICTORY_KEYS'] = $s.keys }
        $events = Join-Path $out 'events.jsonl'
        $envs['VICTORY_EVENTS'] = $events

        $log = Join-Path $out 'run.log'
        $csv = Join-Path $out 'paging.csv'
        $stop = Join-Path $out '.stop'
        $job = Start-PagingCounters -Csv $csv -StopFile $stop
        try {
            $run = Invoke-VictoryRun -Victory $paths.Victory -Exe $exe -Log $log -Seconds $s.seconds -Env $envs -Console $console
        }
        finally {
            New-Item -ItemType File $stop -Force | Out-Null
            Wait-Job $job -Timeout 10 | Out-Null
            Remove-Job $job -Force
        }
    }
    finally {
        if ($SnapshotAs) {
            Copy-Folder $title (Join-Path $paths.Harness "snapshots\$SnapshotAs")
            Write-Host "snapshot       '$SnapshotAs' saved from the run's end state"
        }
        if (-not $Keep) {
            Copy-Folder $backup $title
        }
    }

    $r = Read-VictoryLog -Log $log -Csv $csv
    $fails = Test-Pass $r $s.pass
    $commit = (git -C $script:RepoRoot rev-parse --short HEAD) 2>$null
    $dirty = [bool]((git -C $script:RepoRoot status --porcelain --untracked-files=no) 2>$null)
    $result = [ordered]@{
        scenario = $ScenarioName; time = $stamp; commit = $commit; uncommitted_changes = $dirty
        console = $console; snapshot = $s.snapshot; preset = $s.preset; keys = $s.keys; env = $envs
        seconds = $s.seconds; ran = $run.Ran; exited_by_itself = $run.Exited
        result = $r; passed = ($fails.Count -eq 0); failures = $fails
    }
    $result | ConvertTo-Json -Depth 6 | Out-File (Join-Path $out 'result.json') -Encoding utf8
    $verdict = 'FAIL'; if ($fails.Count -eq 0) { $verdict = 'PASS' }
    $median = 'n/a'; if ($r.WorldMedianMs) { $median = "$($r.WorldMedianMs) ms" }
    Write-Host ("{0,-4} {1}: {2} frames, world {3} (dropped {4}), peak commit {5} MB, removals {6}, crashes {7}" -f `
        $verdict, $ScenarioName, $r.FramesShown, $median, $r.WorldDropped, $r.PeakCommitMB, $r.Removals, $r.Crashes)
    foreach ($f in $fails) { Write-Host "       - $f" }
    $script:LastResult = $out
    return ($fails.Count -eq 0)
}

# The scripted-keys form (VICTORY_KEYS) of the presses recorded in an
# events file: every replayable key or pad press, at its input-clock time.
# Held keys (movement) replay as one 0.2 s press: tune those by hand.
function ConvertTo-Keys([string]$Events) {
    $keys = @()
    foreach ($line in Get-Content $Events) {
        $e = $line | ConvertFrom-Json
        if ($e.kind -ne 'input' -or -not $e.down -or $e.name -like 'vk*') { continue }
        $keys += ('{0}:{1}' -f [math]::Round([double]$e.it, 1).ToString([Globalization.CultureInfo]::InvariantCulture), $e.name)
    }
    return ($keys -join ',')
}

switch ($Command) {
    'record' {
        if (-not $Name) { throw 'record needs a scenario name' }
        $envs = [ordered]@{}
        foreach ($pair in ($Env -split ';' | Where-Object { $_ -match '=' })) {
            $k, $v = $pair -split '=', 2
            $envs[$k.Trim()] = $v.Trim()
        }
        $s = [pscustomobject]@{ seconds = $Seconds; snapshot = $Snapshot; preset = $Preset; env = [pscustomobject]$envs; pass = $null }
        Write-Host "recording      play, then close the title (at most $Seconds s)"
        Invoke-Scenario $Name $s | Out-Null
        $events = Join-Path $script:LastResult 'events.jsonl'
        $r = Get-Content (Join-Path $script:LastResult 'result.json') -Raw | ConvertFrom-Json
        $keys = ''
        if (Test-Path $events) { $keys = ConvertTo-Keys $events }
        $scenario = [ordered]@{
            description = "Recorded $(Get-Date -Format 'yyyy-MM-dd HH:mm') with scripts/harness.ps1 record."
            seconds     = [math]::Max(60, [int]$r.ran)
        }
        if ($Snapshot) { $scenario.snapshot = $Snapshot }
        if ($Preset) { $scenario.preset = $Preset }
        if ($keys) { $scenario.keys = $keys }
        if ($envs.Count) { $scenario.env = $envs }
        $scenario.pass = [ordered]@{ reach_world = [bool]$r.result.ReachedWorld; max_crashes = 0; max_removals = 0 }
        $file = Join-Path $scenarioDir "$Name.json"
        $scenario | ConvertTo-Json -Depth 4 | Out-File $file -Encoding ascii
        Write-Host "scenario       $file ($(@($keys -split ',' | Where-Object { $_ }).Count) presses)"
    }
    'list' {
        Write-Host 'scenarios:'
        Get-ChildItem $scenarioDir -Filter *.json | ForEach-Object {
            $s = Get-Content $_.FullName -Raw | ConvertFrom-Json
            Write-Host ("  {0,-18} {1,4} s  snapshot={2} preset={3}" -f $_.BaseName, $s.seconds, $s.snapshot, $s.preset)
        }
        Write-Host "presets:   $((Get-ChildItem (Join-Path $paths.Harness 'presets') -Filter *.json | ForEach-Object BaseName) -join ', ')"
        Write-Host "snapshots: $((Get-ChildItem (Join-Path $paths.Harness 'snapshots') -Directory | ForEach-Object Name) -join ', ')"
        Write-Host "harness folder: $($paths.Harness)"
    }
    'snapshot' {
        if (-not $Name) { throw 'snapshot needs a name' }
        if (Get-Process victory -ErrorAction SilentlyContinue) { throw 'close the title first' }
        Copy-Folder (Get-TitleData) (Join-Path $paths.Harness "snapshots\$Name")
        Write-Host "snapshot '$Name' saved"
    }
    'restore' {
        $backup = Join-Path $paths.Harness 'backup\data'
        if (-not (Test-Path $backup)) { throw 'no backup yet' }
        Copy-Folder $backup (Get-TitleData)
        Write-Host 'data folder restored from the last backup'
    }
    'run' {
        if (-not $Name) { throw 'run needs a scenario name' }
        if (-not (Invoke-Scenario $Name)) { exit 1 }
    }
    'run-all' {
        $failed = 0
        foreach ($f in Get-ChildItem $scenarioDir -Filter *.json) {
            $s = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($s.snapshot -and -not (Test-Path (Join-Path $paths.Harness "snapshots\$($s.snapshot)"))) {
                Write-Host "SKIP $($f.BaseName): no snapshot '$($s.snapshot)'"
                continue
            }
            if (-not (Invoke-Scenario $f.BaseName)) { $failed++ }
        }
        if ($failed) { exit 1 }
    }
}
