<#
.SYNOPSIS
  The test harness: runs the title in repeatable scenarios and records results.

.DESCRIPTION
  audit: checks the title's content without running it, against the last
  audit: every shader in the game's archive, the pipelines and the texture
  descriptions earlier runs recorded (layouts, detiles, CPU cost). Run it
  after a translator or texture change, before any scenario:
    .\scripts\harness.ps1 audit

  Heavy features get their own scenarios, run on demand (world-rt: the
  ray-tracing structure builder on).

  A scenario (scenarios/<name>.json in the repo) names:
    seconds     how long to run
    console     series-s | series-x (default series-s: 1080p, the one a
                16 GB machine runs at a usable rate; series-x renders 4K)
    snapshot    a saved data folder to start from (optional)
    preset      a graphics preset to write into the title's settings (optional)
    keys        scripted input, VICTORY_KEYS form (optional): "<s>:Enter" at a time,
                "<s>@<milestone>:Enter" after a milestone, "<from>..<milestone>/<every>:Enter"
                repeated until one; ":<ms>" after the key holds it. Milestones are the
                stems of files the title opens (crates/victory-hle/src/milestone.rs)
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
    [Parameter(Position = 0)][ValidateSet('list', 'run', 'run-all', 'snapshot', 'restore', 'record', 'audit', 'symbols')]
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
    [string]$SnapshotAs = '',
    # Skip the prepare step (shader cache brought up to date before a run).
    [switch]$NoPrepare,
    # Run the diagnostics build (ninja diag: target\diag\victory.exe), which
    # logs why draws are dropped, per reason, beside the frame lines.
    [switch]$Diag,
    # Run another build of victory.exe (a control run with an older build).
    [string]$Victory = '',
    # Leave the machine's power mode as it is (a mode set by hand).
    [switch]$KeepPower
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\victory-run.ps1"

$paths = Get-VictoryPaths
if ($Diag) { $paths.Victory = Join-Path $script:RepoRoot 'target\diag\victory.exe' }
if ($Victory) { $paths.Victory = (Resolve-Path $Victory).Path }
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
    # Mirrored in place (robocopy /MIR): a file the title just stopped may
    # hold for a moment is retried, and the folder is never emptied first.
    # (Removing it first once left the data folder half deleted when one
    # file stayed locked, and the next run backed up that half.)
    if (-not (Test-Path $From)) { throw "no $From to copy" }
    $r = Start-Process robocopy -ArgumentList "`"$From`" `"$To`" /MIR /R:20 /W:1 /NFL /NDL /NJH /NJS /NP" -Wait -PassThru -WindowStyle Hidden
    if ($r.ExitCode -ge 8) { throw "copying $From to $To failed (robocopy $($r.ExitCode))" }
}

# A data folder worth backing up: the title's settings file is in it.
function Test-TitleData([string]$Dir) {
    return [bool](Get-ChildItem $Dir -Recurse -Filter settings.xml -ErrorAction SilentlyContinue | Select-Object -First 1)
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

# The prepare step: `victory precompile` with the run's switches, so every
# shader the title ships is translated (and, once recipes exist, every host
# pipeline built) before the run instead of during it. The cache keys on the
# switches (VICTORY_PROFILE, ...), so this runs with them set. A warm cache
# takes seconds.
function Invoke-Prepare([hashtable]$Envs, [string]$Log) {
    $saved = @{}
    foreach ($k in $Envs.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, [string]$Envs[$k], 'Process')
    }
    try {
        $pcArgs = 'precompile'
        # Host pipelines too, when this build of victory can replay recipes.
        $help = cmd /c "`"$($paths.Victory)`" precompile --help 2>&1"
        if (($help | Out-String) -match '--pipelines') { $pcArgs += ' --pipelines' }
        # Through cmd: Windows PowerShell 5.1 turns a native program's
        # stderr (our log lines) into terminating errors under 'Stop'.
        cmd /c "`"`"$($paths.Victory)`" $pcArgs > `"$Log`" 2>&1`""
        $done = Select-String -Path $Log -Pattern '^done|^pipelines' | ForEach-Object { $_.Line.Trim() }
        foreach ($line in $done) { Write-Host "prepare        $line" }
    }
    finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
}

# The offline audit: what the title's content needs, found without running
# it. Shaders: every shader in the game's archive translated (cached
# translations are only looked up). Pipelines: the recipes earlier runs
# recorded, built for this machine. Textures: the descriptions earlier runs
# recorded, laid out and detiled on the CPU, with the cost of each kind.
# The result is compared with the last audit: new failure reasons and
# higher counts are reported, and the audit fails if a count went up.
function Invoke-Audit {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $root = Join-Path $paths.Harness 'audits'
    $last = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    $out = Join-Path $root $stamp
    New-Item -ItemType Directory -Force $out | Out-Null
    $envs = @{ VICTORY_PROFILE = 'low' }
    $saved = @{}
    foreach ($k in $envs.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, [string]$envs[$k], 'Process')
    }
    try {
        $pc = Join-Path $out 'precompile.log'
        cmd /c "`"`"$($paths.Victory)`" precompile --pipelines > `"$pc`" 2>&1`""
        $tx = Join-Path $out 'textures.log'
        $tj = Join-Path $out 'textures.json'
        cmd /c "`"`"$($paths.Victory)`" audit textures --json `"$tj`" > `"$tx`" 2>&1`""
    }
    finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }

    $a = [ordered]@{ shaders = 0; shaders_failed = 0; reasons = [ordered]@{}; pipelines = 0; pipelines_failed = 0; pipeline_failures = @() }
    $section = ''
    foreach ($line in Get-Content $pc) {
        if ($line -match '^done\s+(\d+) shaders: .*, (\d+) failed') {
            $a.shaders = [int]$Matches[1]; $a.shaders_failed = [int]$Matches[2]; $section = 'reasons'; continue
        }
        if ($line -match '^done\s+(\d+) pipelines: .*, (\d+) failed') {
            $a.pipelines = [int]$Matches[1]; $a.pipelines_failed = [int]$Matches[2]; $section = 'pipelines'; continue
        }
        if ($section -eq 'reasons' -and $line -match '^\s+(\d+)\s+(.+)$') { $a.reasons[$Matches[2].Trim()] = [int]$Matches[1]; continue }
        if ($section -eq 'pipelines' -and $line -match '^\s+failed\s+(.+)$') { $a.pipeline_failures += $Matches[1].Trim(); continue }
        if ($line -match '^(slowest|replaying|recipes)') { if ($line -match '^slowest') { $section = '' } }
    }
    $t = $null
    if (Test-Path $tj) { $t = Get-Content $tj -Raw | ConvertFrom-Json }
    $a.textures = $t
    $a | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out 'audit.json') -Encoding utf8

    Write-Host "audit          $out"
    Write-Host ("shaders        {0} found, {1} do not translate" -f $a.shaders, $a.shaders_failed)
    foreach ($r in $a.reasons.Keys) { Write-Host ("  {0,6}  {1}" -f $a.reasons[$r], $r) }
    Write-Host ("pipelines      {0} recorded, {1} fail on this machine" -f $a.pipelines, $a.pipelines_failed)
    if ($t) {
        $nl = 0; foreach ($p in $t.no_layout.PSObject.Properties) { $nl += $p.Value }
        Write-Host ("textures       {0} recorded, {1} without a console layout, {2} fail to detile" -f $t.descriptions, $nl, $t.detile_failures)
        foreach ($p in $t.no_layout.PSObject.Properties) { Write-Host ("  {0,6}  no layout: {1}" -f $p.Value, $p.Name) }
        $top = @($t.kinds | Sort-Object { -[double]$_.ms } | Select-Object -First 5)
        foreach ($k in $top) { Write-Host ("  detile  format {0,3} swizzle {1,2}: {2,6} textures, {3,8:N1} ms" -f $k.format, $k.swizzle, $k.textures, [double]$k.ms) }
    } else {
        Write-Host 'textures       none recorded yet (a run records them)'
    }

    if (-not $last) { Write-Host 'baseline       first audit: nothing to compare'; return $true }
    $b = Get-Content (Join-Path $last.FullName 'audit.json') -Raw | ConvertFrom-Json
    $worse = @()
    if ($a.shaders_failed -gt $b.shaders_failed) { $worse += "shaders failing $($b.shaders_failed) -> $($a.shaders_failed)" }
    if ($a.pipelines_failed -gt $b.pipelines_failed) { $worse += "pipelines failing $($b.pipelines_failed) -> $($a.pipelines_failed)" }
    foreach ($r in $a.reasons.Keys) {
        $old = 0; $prop = $b.reasons.PSObject.Properties[$r]; if ($prop) { $old = [int]$prop.Value }
        if ($a.reasons[$r] -gt $old) { $worse += "reason '$r' $old -> $($a.reasons[$r])" }
    }
    if ($t -and $b.textures -and $t.detile_failures -gt $b.textures.detile_failures) { $worse += "texture detile failures $($b.textures.detile_failures) -> $($t.detile_failures)" }
    Write-Host ("against        {0}: shaders failing {1} -> {2}, pipelines failing {3} -> {4}" -f $last.Name, $b.shaders_failed, $a.shaders_failed, $b.pipelines_failed, $a.pipelines_failed)
    if ($worse) { foreach ($w in $worse) { Write-Host "WORSE          $w" }; return $false }
    Write-Host 'PASS audit: nothing got worse'
    return $true
}

# The local symbol store for this layer's own builds (docs/directions.md E2),
# outside the repo: %LOCALAPPDATA%\victory\symbols, in the symbol-server
# layout `victory.pdb\<KEY>\victory.pdb` (KEY: the exe's CodeView GUID and
# age), with the exe beside it under the same key. Every run files the
# build it runs, so a crash log's key always finds its exact PDB. Builds
# are never matched by anything but the exact key.
$symbolStore = Join-Path $env:LOCALAPPDATA 'victory\symbols'
function Save-Symbols([string]$Exe) {
    $info = cmd /c "`"$Exe`" inspect `"$Exe`" 2>&1"
    $keyLine = $info | Select-String 'pdb\s+(\S+)\s+\(key ([0-9A-F]+)\)' | Select-Object -First 1
    if (-not $keyLine) { Write-Host 'symbols        no CodeView key in the exe: not filed'; return $null }
    $key = $keyLine.Matches[0].Groups[2].Value
    $pdbName = Split-Path $keyLine.Matches[0].Groups[1].Value -Leaf
    $pdb = Join-Path (Split-Path $Exe -Parent) $pdbName
    $dir = Join-Path $symbolStore "$pdbName\$key"
    $exeDir = Join-Path $symbolStore "$(Split-Path $Exe -Leaf)\$key"
    if (Test-Path (Join-Path $dir $pdbName)) { return $key }
    if (-not (Test-Path $pdb)) { Write-Host "symbols        no $pdb beside the exe: key $key not filed"; return $key }
    New-Item -ItemType Directory -Force $dir, $exeDir | Out-Null
    Copy-Item $pdb (Join-Path $dir $pdbName)
    Copy-Item $Exe (Join-Path $exeDir (Split-Path $Exe -Leaf))
    $blake = ($info | Select-String '^blake3\s+(\S+)' | Select-Object -First 1).Matches[0].Groups[1].Value
    $commit = (git -C $script:RepoRoot rev-parse --short=12 HEAD) 2>$null
    [ordered]@{ key = $key; pdb = $pdbName; blake3 = $blake; head = $commit; filed = (Get-Date -Format s); from = $Exe } |
        ConvertTo-Json -Compress | Add-Content (Join-Path $symbolStore 'index.jsonl')
    Write-Host "symbols        filed $pdbName $key"
    return $key
}

# Keys a run or crash log names: kept forever. Others go after 30 days.
function Invoke-SymbolsPrune {
    $keep = @{}
    foreach ($f in Get-ChildItem (Join-Path $paths.Harness 'results') -Recurse -Filter result.json -ErrorAction SilentlyContinue) {
        $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
        if ($j.build.victory_key) { $keep[$j.build.victory_key] = $true }
    }
    foreach ($log in Get-ChildItem $paths.Data -Recurse -Filter crashes.log -ErrorAction SilentlyContinue) {
        foreach ($m in (Select-String -Path $log.FullName -Pattern 'build victory key=([0-9A-F]+)' -AllMatches)) { $keep[$m.Matches[0].Groups[1].Value] = $true }
    }
    $cut = (Get-Date).AddDays(-30); $removed = 0; $kept = 0
    foreach ($d in Get-ChildItem $symbolStore -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem $_.FullName -Directory }) {
        if ($keep[$d.Name] -or $d.LastWriteTime -gt $cut) { $kept++; continue }
        Remove-Item -Recurse -Force $d.FullName; $removed++
    }
    Write-Host "symbols        $kept kept ($($keep.Count) keys named by runs or crash logs), $removed removed"
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
    $console = 'series-s'; if ($s.console) { $console = $s.console }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $out = Join-Path $paths.Harness "results\$stamp-$ScenarioName"
    New-Item -ItemType Directory -Force $out | Out-Null
    Write-Host "scenario       $ScenarioName -> $out"

    [void](Save-Symbols $paths.Victory)
    $title = Get-TitleData
    $backup = Join-Path $paths.Harness 'backup\data'
    if (-not (Test-TitleData $title)) {
        throw "the data folder $title has no settings file: not backing it up. Put a good one back first (harness.ps1 restore, or copy a snapshot)"
    }
    if (Test-Path $backup) { Copy-Folder $backup "$backup.prev" }
    Copy-Folder $title $backup
    $envs = @{}
    $run = $null
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
        if (-not $NoPrepare) { Invoke-Prepare $envs (Join-Path $out 'precompile.log') }
        $events = Join-Path $out 'events.jsonl'
        $envs['VICTORY_EVENTS'] = $events
        # Live input from the control app: it appends commands here.
        $control = Join-Path $out 'control.txt'
        New-Item -ItemType File -Force $control | Out-Null
        $envs['VICTORY_CONTROL'] = $control

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
        # Only a run that happened leaves an end state worth keeping.
        if ($SnapshotAs -and $run) {
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
    # The exact builds that ran (the run's `build` event): this layer's
    # CodeView key (its PDB in the symbol store) and the title's identity.
    if (Test-Path $events) {
        $build = Get-Content $events | Where-Object { $_ -match '"kind":"build"' } | Select-Object -First 1
        if ($build) { $result.build = $build | ConvertFrom-Json }
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
# events file: every replayable key or pad press at its input-clock time,
# with how long it was held when that was more than a tap
# (`<seconds>:<key>:<ms>`; a cutscene skips on a held A).
function ConvertTo-Keys([string]$Events) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $presses = New-Object System.Collections.ArrayList
    $open = @{}
    foreach ($line in Get-Content $Events) {
        $e = $line | ConvertFrom-Json
        if ($e.kind -ne 'input' -or $e.name -like 'vk*') { continue }
        $id = "$($e.device)/$($e.name)"
        if ($e.down) {
            $open[$id] = $presses.Add([pscustomobject]@{ At = [double]$e.it; Name = $e.name; Ms = 200 })
        } elseif ($open.ContainsKey($id)) {
            $p = $presses[$open[$id]]
            $p.Ms = [int](([double]$e.it - $p.At) * 1000)
            $open.Remove($id)
        }
    }
    $keys = foreach ($p in $presses) {
        $at = [math]::Round($p.At, 1).ToString($inv)
        if ($p.Ms -gt 400) { "${at}:$($p.Name):$($p.Ms)" } else { "${at}:$($p.Name)" }
    }
    return ($keys -join ',')
}

# Full power for runs: when the machine's own power-mode script exists
# (outside the repo: ..\tools\power-profile.ps1 beside this checkout, which
# sets the laptop's fan and power mode), a run switches to Turbo first, and
# afterwards back to Silent while it is before $QuietUntil o'clock (the
# machine stays in Turbo after that). Without the script nothing changes.
$QuietUntil = 9
$powerScript = Join-Path (Split-Path $script:RepoRoot -Parent) 'tools\power-profile.ps1'
function Set-PowerMode([string]$Mode) {
    if (-not (Test-Path $powerScript)) { return $false }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $powerScript -Mode $Mode | Out-Null
    return $LASTEXITCODE -eq 0
}
function Enter-FullPower {
    if (Set-PowerMode 'turbo') { Write-Host 'power          Turbo for this run'; Start-Sleep -Seconds 3 }
}
function Exit-FullPower {
    if ((Get-Date).Hour -lt $QuietUntil -and (Set-PowerMode 'silent')) {
        Write-Host "power          back to Silent (quiet until $($QuietUntil):00)"
    }
}

if (-not $KeepPower -and $Command -in 'run', 'run-all', 'audit', 'record') { Enter-FullPower }
try {
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
    'symbols' {
        $key = Save-Symbols $paths.Victory
        Write-Host "symbols        current build key $key; store $symbolStore"
        Invoke-SymbolsPrune
    }
    'audit' {
        if (-not (Invoke-Audit)) { exit 1 }
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
}
finally {
    if (-not $KeepPower -and $Command -in 'run', 'run-all', 'audit', 'record') { Exit-FullPower }
}
