# Shared by scripts/smoke.ps1 and scripts/harness.ps1 (dot-source it).
# Starts a run of the title, samples Windows' paging counters beside it,
# stops it after a set time, and reads the log into one result object.
# Windows PowerShell 5.1.

$script:RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path

# Paths from victory.toml (single-quoted TOML strings), with VIctory's defaults.
function Get-VictoryPaths {
    $toml = Join-Path $script:RepoRoot 'victory.toml'
    $read = {
        param($key)
        if (-not (Test-Path $toml)) { return $null }
        $m = Select-String -Path $toml -Pattern "^\s*$key\s*=\s*'([^']+)'" | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value }
        return $null
    }
    $game = & $read 'game_dir'
    $data = & $read 'data_dir'
    if (-not $data) { $data = Join-Path $env:LOCALAPPDATA 'victory\data' }
    if ($env:VICTORY_GAME_DIR) { $game = $env:VICTORY_GAME_DIR }
    if ($env:VICTORY_DATA_DIR) { $data = $env:VICTORY_DATA_DIR }
    [pscustomobject]@{
        Game    = $game
        Data    = $data
        Harness = Join-Path $env:LOCALAPPDATA 'victory\harness'
        Victory = Join-Path $script:RepoRoot 'target\release\victory.exe'
    }
}

# Samples paging counters every 2 s into a CSV until $StopFile exists.
function Start-PagingCounters {
    param([string]$Csv, [string]$StopFile)
    Start-Job -ArgumentList $Csv, $StopFile -ScriptBlock {
        param($csv, $stop)
        $names = '\Memory\Pages Input/sec', '\Memory\Available MBytes', '\Memory\Committed Bytes',
            '\Process(victory)\Page Faults/sec', '\Process(victory)\Working Set', '\Process(victory)\Private Bytes'
        'time,counter,value' | Out-File $csv -Encoding ascii
        while (-not (Test-Path $stop)) {
            $s = Get-Counter -Counter $names -ErrorAction SilentlyContinue
            if ($s) {
                $t = $s.Timestamp.ToUniversalTime().ToString('HH:mm:ss')
                foreach ($c in $s.CounterSamples) {
                    "$t,$($c.Path -replace '^\\\\[^\\]+',''),$([math]::Round($c.CookedValue, 1))" | Out-File $csv -Append -Encoding ascii
                }
            }
            Start-Sleep -Seconds 2
        }
    }
}

# Runs the title for $Seconds (or until it exits) with $Env switches applied
# to this process; returns @{ Exited; Ran }.
function Invoke-VictoryRun {
    param(
        [string]$Victory, [string]$Exe, [string]$Log, [int]$Seconds,
        [hashtable]$Env = @{}, [string]$Console = 'series-x'
    )
    if (Get-Process victory -ErrorAction SilentlyContinue) { throw 'victory.exe is already running' }
    $saved = @{}
    foreach ($k in $Env.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, [string]$Env[$k], 'Process')
    }
    try {
        $started = Get-Date
        $cmdline = "`"$Victory`" run `"$Exe`" --execute --console $Console > `"$Log`" 2>&1"
        # cmd /c strips the outer quotes of a line with several quoted parts:
        # one more pair around the whole line keeps the inner ones.
        $proc = Start-Process -FilePath cmd.exe -ArgumentList '/c', "`"$cmdline`"" -PassThru -WindowStyle Hidden
        $exited = $proc.WaitForExit($Seconds * 1000)
        if (-not $exited) {
            Get-Process victory -ErrorAction SilentlyContinue | Stop-Process -Force
            $proc.WaitForExit(10000) | Out-Null
        }
        return @{ Exited = $exited; Ran = [int]((Get-Date) - $started).TotalSeconds }
    }
    finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
}

function Get-Median($values) {
    $s = @($values | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    return [math]::Round([double]$s[[int]($s.Count / 2)], 1)
}

# Reads a run log (and optional paging CSV) into one result object.
function Read-VictoryLog {
    param([string]$Log, [string]$Csv = '')
    $text = ''
    if (Test-Path $Log) { $text = (Get-Content $Log -Raw) -replace "$([char]27)\[[0-9;]*m", '' }
    if (-not $text) { $text = '' }
    $lines = $text -split "`r?`n"
    $frames = @()
    foreach ($l in $lines) {
        if ($l -match '([\d.]+) fps, ([\d.]+) ms/frame .*?, ([\d.]+) draws/frame, dropped ([\d.]+) without a host pipeline \((\d+) being made\)') {
            $frames += [pscustomobject]@{
                Fps = [double]$Matches[1]; Ms = [double]$Matches[2]; Draws = [double]$Matches[3]
                Dropped = [double]$Matches[4]; Making = [int]$Matches[5]
            }
        }
    }
    # The world: frame lines with more than 300 draws (menus have under 50).
    $world = @($frames | Where-Object { $_.Draws -gt 300 })
    $peak = 0
    foreach ($l in $lines) {
        if ($l -match 'memory: \d+ MB committed \(peak (\d+) MB\)') { $peak = [math]::Max($peak, [int]$Matches[1]) }
    }
    $adapter = ''
    $a = $lines | Where-Object { $_ -match 'host adapter adapter=' } | Select-Object -First 1
    if ($a) { $adapter = ($a -replace '.*adapter=', '').Trim() }
    $hard = $null
    if ($Csv -and (Test-Path $Csv)) {
        $rows = @(Import-Csv $Csv | Where-Object { $_.counter -match 'pages input/sec' })
        if ($rows.Count) {
            $vals = $rows | ForEach-Object { [double]$_.value }
            $hard = [pscustomobject]@{
                Median = Get-Median $vals
                Max    = [math]::Round(($vals | Measure-Object -Maximum).Maximum, 1)
            }
        }
    }
    [pscustomobject]@{
        Adapter        = $adapter
        FrameLines     = $frames.Count
        # Frames shown: fps x the 5 s each frame line covers, summed.
        FramesShown    = [int](($frames | Measure-Object -Property Fps -Sum).Sum * 5)
        WorldLines     = $world.Count
        ReachedWorld   = ($world.Count -gt 0)
        WorldMedianMs  = Get-Median ($world | ForEach-Object { $_.Ms })
        WorldMedianFps = Get-Median ($world | ForEach-Object { $_.Fps })
        WorldDropped   = Get-Median ($world | ForEach-Object { $_.Dropped })
        WorldMaking    = Get-Median ($world | ForEach-Object { $_.Making })
        PeakCommitMB   = $peak
        Removals       = @($lines | Where-Object { $_ -match 'device removed' }).Count
        Crashes        = @($lines | Where-Object { $_ -match 'unhandled exception' }).Count
        HardFaults     = $hard
    }
}
