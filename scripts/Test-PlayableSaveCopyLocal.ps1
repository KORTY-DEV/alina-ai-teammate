[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SaveCopy,
    [string]$FactorioExe,
    [int]$BenchmarkTicks = 12000,
    [int]$TimeoutSeconds = 360
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$safeRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot '.test-output\real-save-playable'))
$SaveCopy = [System.IO.Path]::GetFullPath($SaveCopy)
if (-not $SaveCopy.StartsWith($safeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to load a save outside the isolated playable-test root: $SaveCopy"
}
if (-not (Test-Path -LiteralPath $SaveCopy)) { throw "Save copy not found: $SaveCopy" }
if (Get-Process factorio -ErrorAction SilentlyContinue) {
    throw 'Factorio is already running; refusing to mix the local inspection with another game process.'
}

if (-not $FactorioExe) {
    $FactorioExe = @(
        'D:\Games\Factorio Space Age v2.1.12b\Factorio Space Age v2.1.12b\bin\x64\factorio.exe',
        'C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe'
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $FactorioExe) { throw 'Factorio executable not found.' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runRoot = Join-Path $safeRoot "local-$stamp"
$writeData = Join-Path $runRoot 'write-data'
$logs = Join-Path $runRoot 'logs'
$sourceMods = Join-Path $safeRoot 'current\mods'
$mods = Join-Path $runRoot 'mods'
New-Item -ItemType Directory -Path $writeData, $logs, $mods -Force | Out-Null
Copy-Item -Path (Join-Path $sourceMods '*') -Destination $mods -Recurse -Force

$sourceAlina = Join-Path $projectRoot 'factorio-mod\alina-ai-teammate_0.1.0'
$targetAlina = Join-Path $mods 'alina-ai-teammate_0.1.0'
if (-not (Test-Path -LiteralPath $targetAlina)) { New-Item -ItemType Directory -Path $targetAlina | Out-Null }
Copy-Item -Path (Join-Path $sourceAlina '*') -Destination $targetAlina -Recurse -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'tests\fixtures\alina-real-save-test_0.1.0') `
    -Destination (Join-Path $mods 'alina-real-save-test_0.1.0') -Recurse

$modListPath = Join-Path $mods 'mod-list.json'
$modList = Get-Content -LiteralPath $modListPath -Raw | ConvertFrom-Json
$existing = @($modList.mods) | Where-Object name -eq 'alina-real-save-test' | Select-Object -First 1
if ($existing) { $existing.enabled = $true } else {
    $modList.mods = @($modList.mods) + [pscustomobject]@{ name = 'alina-real-save-test'; enabled = $true }
}
[IO.File]::WriteAllText($modListPath, ($modList | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))

$factorioInstall = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $FactorioExe))))
$configPath = Join-Path $runRoot 'config.ini'
"[path]`r`nread-data=$(Join-Path $factorioInstall 'data')`r`nwrite-data=$writeData`r`n" |
    Set-Content -LiteralPath $configPath -Encoding UTF8
$resultPath = Join-Path $writeData 'script-output\alina\real-save-result.json'
$stdout = Join-Path $logs 'factorio.stdout.log'
$stderr = Join-Path $logs 'factorio.stderr.log'
$beforeHash = (Get-FileHash -LiteralPath $SaveCopy -Algorithm SHA256).Hash
$arguments = '--config "{0}" --mod-directory "{1}" --benchmark "{2}" --benchmark-ticks {3} --benchmark-runs 1 --benchmark-ignore-paused --benchmark-sanitize --no-log-rotation' -f `
    $configPath, $mods, $SaveCopy, $BenchmarkTicks
$process = Start-Process -FilePath $FactorioExe -ArgumentList $arguments -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$processHandle = $process.Handle
try {
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "Single-process copied-save test timed out after $TimeoutSeconds seconds."
    }
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}
$process.WaitForExit()
$process.Refresh()
$afterHash = (Get-FileHash -LiteralPath $SaveCopy -Algorithm SHA256).Hash
if ($afterHash -ne $beforeHash) { throw 'Copied save changed during benchmark inspection.' }
if ($process.ExitCode -ne 0) { throw "Factorio local benchmark failed. See $stdout" }
if (-not (Test-Path -LiteralPath $resultPath)) { throw "Real-save result missing: $resultPath" }
$result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $result.ok -or $result.last_task.type -notin @('expand_line', 'repair_power')) {
    throw "Copied-save factory development was not verified: $($result | ConvertTo-Json -Depth 10 -Compress)"
}
$benchmarkSummary = Select-String -LiteralPath $stdout `
    -Pattern 'avg:\s+([0-9.]+) ms,\s+min:\s+([0-9.]+) ms,\s+max:\s+([0-9.]+) ms' | Select-Object -Last 1
$averageUpdateMs = $null
if ($benchmarkSummary -and $benchmarkSummary.Matches.Count -gt 0) {
    $averageUpdateMs = [double]$benchmarkSummary.Matches[0].Groups[1].Value
}
[pscustomobject]@{
    Result = 'LOCAL PLAYABLE SAVE COPY TEST OK'
    Mode = 'single-process benchmark; no server, client, RCON or network'
    SaveCopy = $SaveCopy
    SaveHash = $afterHash
    Task = $result.last_task.type
    TaskResult = $result.last_task.result
    BeforeIndexedEntities = $result.before.indexed_entities
    AfterIndexedEntities = $result.after.indexed_entities
    FirstTask = $result.first_task_type
    FirstTaskDelayTicks = $result.first_task_delay
    AverageUpdateMs = $averageUpdateMs
    RunRoot = $runRoot
    Evidence = $resultPath
} | Format-List
