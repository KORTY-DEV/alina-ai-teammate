[CmdletBinding()]
param(
    [string]$FactorioExe,
    [int]$BenchmarkTicks = 20000,
    [int]$BenchmarkRuns = 3,
    [double]$MaxAddedMillisecondsPerTick = 0.20
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot ('.test-output\performance-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))))
if (-not $testRoot.StartsWith($projectRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe performance output path.' }

if (-not $FactorioExe) {
    $FactorioExe = @(
        'D:\Games\Factorio Space Age v2.1.12b\Factorio Space Age v2.1.12b\bin\x64\factorio.exe',
        'C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe'
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $FactorioExe -or -not (Test-Path -LiteralPath $FactorioExe)) {
    throw 'Factorio executable not found. Pass -FactorioExe explicitly.'
}

$factorioInstall = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $FactorioExe))))
$readData = Join-Path $factorioInstall 'data'
$mods = Join-Path $testRoot 'mods'
$writeData = Join-Path $testRoot 'data'
New-Item -ItemType Directory -Path $mods, $writeData -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'factorio-mod\alina-ai-teammate_0.1.0') `
    -Destination (Join-Path $mods 'alina-ai-teammate_0.1.0') -Recurse
Copy-Item -LiteralPath (Join-Path $projectRoot 'tests\fixtures\alina-performance-test_0.1.0') `
    -Destination (Join-Path $mods 'alina-performance-test_0.1.0') -Recurse

$configPath = Join-Path $testRoot 'factorio.ini'
[System.IO.File]::WriteAllText($configPath,
    "[path]`r`nread-data=$readData`r`nwrite-data=$writeData`r`n",
    [Text.UTF8Encoding]::new($false))

function Write-ModList([bool]$AlinaEnabled) {
    $value = @{ mods = @(
        @{ name = 'base'; enabled = $true },
        @{ name = 'alina-performance-test'; enabled = $true },
        @{ name = 'alina-ai-teammate'; enabled = $AlinaEnabled }
    ) } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText((Join-Path $mods 'mod-list.json'), $value,
        [Text.UTF8Encoding]::new($false))
}

function Invoke-Factorio([string]$Arguments, [string]$Name) {
    $stdout = Join-Path $testRoot ($Name + '.stdout.log')
    $stderr = Join-Path $testRoot ($Name + '.stderr.log')
    $process = Start-Process -FilePath $FactorioExe -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($process.ExitCode -ne 0) {
        throw "Factorio $Name failed with exit code $($process.ExitCode): $((Get-Content $stderr -Raw -ErrorAction SilentlyContinue))"
    }
    return $stdout
}

function Invoke-Benchmark([string]$Name, [bool]$AlinaEnabled) {
    Write-ModList $AlinaEnabled
    $arguments = ('--config "{0}" --mod-directory "{1}" --benchmark "{2}" ' +
        '--benchmark-ticks {3} --benchmark-runs {4} --benchmark-sanitize --no-log-rotation') -f `
        $configPath, $mods, $mapPath, $BenchmarkTicks, $BenchmarkRuns
    $stdout = Invoke-Factorio $arguments $Name
    $samples = @()
    foreach ($line in Get-Content -LiteralPath $stdout) {
        if ($line -match 'avg:\s+([0-9.]+) ms,\s+min:\s+([0-9.]+) ms,\s+max:\s+([0-9.]+) ms') {
            $samples += [pscustomobject]@{ AverageMs = [double]$Matches[1]; MinimumMs = [double]$Matches[2]; MaximumMs = [double]$Matches[3] }
        }
    }
    if ($samples.Count -ne $BenchmarkRuns) { throw "Benchmark $Name returned $($samples.Count) samples." }
    return $samples
}

Write-ModList $false
$mapPath = Join-Path $testRoot 'large-factory.zip'
Invoke-Factorio ('--config "{0}" --mod-directory "{1}" --create "{2}" --map-gen-seed 737373 --no-log-rotation' -f `
    $configPath, $mods, $mapPath) 'create' | Out-Null
$fixtureResultPath = Join-Path $writeData 'script-output\alina\performance-fixture.json'
$fixtureResult = $null
if (Test-Path -LiteralPath $fixtureResultPath) {
    $fixtureResult = Get-Content -LiteralPath $fixtureResultPath -Raw | ConvertFrom-Json
}

$baselineA = Invoke-Benchmark 'baseline-a' $false
$alinaA = Invoke-Benchmark 'alina-a' $true
$alinaB = Invoke-Benchmark 'alina-b' $true
$baselineB = Invoke-Benchmark 'baseline-b' $false

function Average([object[]]$Rows) { return (($Rows | Measure-Object -Property AverageMs -Average).Average) }
function AverageMaximum([object[]]$Rows) { return (($Rows | Measure-Object -Property MaximumMs -Average).Average) }
$baselineAverage = (Average @($baselineA + $baselineB))
$alinaAverage = (Average @($alinaA + $alinaB))
$baselineMaximumAverage = (AverageMaximum @($baselineA + $baselineB))
$alinaMaximumAverage = (AverageMaximum @($alinaA + $alinaB))
$baselineWorstTick = (@($baselineA + $baselineB) | Measure-Object -Property MaximumMs -Maximum).Maximum
$alinaWorstTick = (@($alinaA + $alinaB) | Measure-Object -Property MaximumMs -Maximum).Maximum
$added = $alinaAverage - $baselineAverage
$tickBudgetPercent = 100 * $added / (1000 / 60)
$syntheticEntities = if ($fixtureResult) { [int]$fixtureResult.entity_count } else { $null }
$result = [ordered]@{
    ok = $added -le $MaxAddedMillisecondsPerTick
    synthetic_entities = $syntheticEntities
    synthetic_entities_requested = 29241
    benchmark_ticks = $BenchmarkTicks
    benchmark_runs_per_side = 2 * $BenchmarkRuns
    baseline_average_ms = [math]::Round($baselineAverage, 4)
    alina_average_ms = [math]::Round($alinaAverage, 4)
    baseline_average_run_max_ms = [math]::Round($baselineMaximumAverage, 4)
    alina_average_run_max_ms = [math]::Round($alinaMaximumAverage, 4)
    baseline_worst_tick_ms = [math]::Round($baselineWorstTick, 4)
    alina_worst_tick_ms = [math]::Round($alinaWorstTick, 4)
    added_ms_per_tick = [math]::Round($added, 4)
    added_percent_of_60_ups_budget = [math]::Round($tickBudgetPercent, 3)
    maximum_allowed_added_ms = $MaxAddedMillisecondsPerTick
    output = $testRoot
}
$resultPath = Join-Path $testRoot 'result.json'
[System.IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json -Depth 5
if (-not $result.ok) { throw "Alina exceeded the performance budget. See $resultPath" }
