[CmdletBinding()]
param(
    [string]$FactorioExe,
    [int]$BenchmarkTicks = 216000,
    [int]$TimingBenchmarkTicks = 20000,
    [double]$MaxAddedMillisecondsPerTick = 8.0,
    [double]$MaxAverageMillisecondsPerTick = 16.0,
    [double]$MaxUpdateMilliseconds = 500.0,
    [int]$MinSyntheticEntities = 50000,
    [int]$MinUsefulCompletedTasks = 2,
    [int]$MaxFailedTasks = 8,
    [int]$MaxCurrentTaskAgeTicks = 108000,
    [bool]$UseInstalledModPack = $true,
    [string]$InstalledModDirectory = (Join-Path $env:APPDATA 'Factorio\mods')
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot ('.test-output\megabase-endurance-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))))
if (-not $testRoot.StartsWith($projectRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe endurance output path.' }

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
if ($UseInstalledModPack) {
    if (-not (Test-Path -LiteralPath $InstalledModDirectory -PathType Container)) {
        throw "Installed Factorio mod directory not found: $InstalledModDirectory"
    }
    Get-ChildItem -LiteralPath $InstalledModDirectory -File -Filter '*.zip' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $mods $_.Name)
    }
    $installedSettings = Join-Path $InstalledModDirectory 'mod-settings.dat'
    if (Test-Path -LiteralPath $installedSettings -PathType Leaf) {
        Copy-Item -LiteralPath $installedSettings -Destination (Join-Path $mods 'mod-settings.dat')
    }
}
Copy-Item -LiteralPath (Join-Path $projectRoot 'factorio-mod\alina-ai-teammate_0.1.0') `
    -Destination (Join-Path $mods 'alina-ai-teammate_0.1.0') -Recurse
Copy-Item -LiteralPath (Join-Path $projectRoot 'tests\fixtures\alina-megabase-endurance-test_0.1.0') `
    -Destination (Join-Path $mods 'alina-megabase-endurance-test_0.1.0') -Recurse

$configPath = Join-Path $testRoot 'factorio.ini'
[System.IO.File]::WriteAllText($configPath,
    "[path]`r`nread-data=$readData`r`nwrite-data=$writeData`r`n`r`n[other]`r`npause-on-focus-lost=false`r`n`r`n[graphics]`r`ngraphics-quality=low`r`nvideo-memory-usage=low`r`ntexture-streaming=true`r`nv-sync=false`r`n",
    [Text.UTF8Encoding]::new($false))

function Write-ModList([bool]$AlinaEnabled) {
    $entries = [System.Collections.Generic.List[object]]::new()
    if ($UseInstalledModPack) {
        $sourceListPath = Join-Path $InstalledModDirectory 'mod-list.json'
        if (-not (Test-Path -LiteralPath $sourceListPath -PathType Leaf)) {
            throw "Installed mod-list.json not found: $sourceListPath"
        }
        $sourceList = Get-Content -LiteralPath $sourceListPath -Encoding UTF8 -Raw | ConvertFrom-Json
        foreach ($entry in $sourceList.mods) {
            if ($entry.name -notin @('alina-ai-teammate', 'alina-megabase-endurance-test')) {
                $entries.Add(@{ name = [string]$entry.name; enabled = [bool]$entry.enabled })
            }
        }
    } else {
        $entries.Add(@{ name = 'base'; enabled = $true })
    }
    $entries.Add(@{ name = 'alina-megabase-endurance-test'; enabled = $true })
    $entries.Add(@{ name = 'alina-ai-teammate'; enabled = $AlinaEnabled })
    $value = @{ mods = @($entries) } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText((Join-Path $mods 'mod-list.json'), $value,
        [Text.UTF8Encoding]::new($false))
}

function Invoke-Factorio([string]$Arguments, [string]$Name) {
    $stdout = Join-Path $testRoot ($Name + '.stdout.log')
    $stderr = Join-Path $testRoot ($Name + '.stderr.log')
    $process = Start-Process -FilePath $FactorioExe -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($process.ExitCode -ne 0) {
        $details = Get-Content $stderr -Raw -ErrorAction SilentlyContinue
        if (-not $details) { $details = Get-Content $stdout -Raw -ErrorAction SilentlyContinue }
        throw "Factorio $Name failed with exit code $($process.ExitCode): $details"
    }
    if (Select-String -Path $stdout, $stderr -Pattern 'desync|desynchron' -Quiet -ErrorAction SilentlyContinue) {
        throw "Factorio $Name reported a desynchronization marker."
    }
    return $stdout
}

function Invoke-Benchmark([string]$Name, [bool]$AlinaEnabled, [int]$Ticks) {
    Write-ModList $AlinaEnabled
    $arguments = ('--config "{0}" --mod-directory "{1}" --benchmark "{2}" ' +
        '--benchmark-ticks {3} --benchmark-runs 1 --benchmark-sanitize --no-log-rotation') -f `
        $configPath, $mods, $mapPath, $Ticks
    $stdout = Invoke-Factorio $arguments $Name
    $sample = $null
    foreach ($line in Get-Content -LiteralPath $stdout) {
        if ($line -match 'avg:\s+([0-9.]+) ms,\s+min:\s+([0-9.]+) ms,\s+max:\s+([0-9.]+) ms') {
            $sample = [pscustomobject]@{
                AverageMs = [double]$Matches[1]
                MinimumMs = [double]$Matches[2]
                MaximumMs = [double]$Matches[3]
            }
        }
    }
    if (-not $sample) { throw "Benchmark $Name did not return a timing sample." }
    return $sample
}

Write-ModList $true
$activeMapPath = Join-Path $testRoot 'active-megabase.zip'
Invoke-Factorio ('--config "{0}" --mod-directory "{1}" --create "{2}" --map-gen-seed 737373 --no-log-rotation' -f `
    $configPath, $mods, $activeMapPath) 'create' | Out-Null

$bootstrapServerData = Join-Path $testRoot 'bootstrap-server-data'
$bootstrapClientData = Join-Path $testRoot 'bootstrap-client-data'
New-Item -ItemType Directory -Path $bootstrapServerData, $bootstrapClientData -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $bootstrapServerData 'saves') -Force | Out-Null
@{ 'service-username' = 'alina-endurance-bootstrap'; 'service-token' = '' } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $bootstrapClientData 'player-data.json') -Encoding UTF8
$bootstrapServerConfig = Join-Path $testRoot 'bootstrap-server.ini'
$bootstrapClientConfig = Join-Path $testRoot 'bootstrap-client.ini'
[System.IO.File]::WriteAllText($bootstrapServerConfig,
    "[path]`r`nread-data=$readData`r`nwrite-data=$bootstrapServerData`r`n", [Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($bootstrapClientConfig,
    "[path]`r`nread-data=$readData`r`nwrite-data=$bootstrapClientData`r`n`r`n[other]`r`nfactorio-username=alina-endurance-bootstrap`r`n`r`n[graphics]`r`ngraphics-quality=low`r`nvideo-memory-usage=low`r`ntexture-streaming=true`r`nv-sync=false`r`n",
    [Text.UTF8Encoding]::new($false))
$playerMapPath = Join-Path $bootstrapServerData 'saves\alina-endurance-player.zip'
$bootstrapServerLog = Join-Path $testRoot 'bootstrap-server.stdout.log'
$bootstrapServerError = Join-Path $testRoot 'bootstrap-server.stderr.log'
$bootstrapClientLog = Join-Path $testRoot 'bootstrap-client.stdout.log'
$bootstrapClientError = Join-Path $testRoot 'bootstrap-client.stderr.log'
$bootstrapServer = $null
$bootstrapClient = $null
try {
    $bootstrapServerArgs = '--config "{0}" --mod-directory "{1}" --start-server "{2}" --bind 127.0.0.1:34621 --server-settings "{3}" --no-log-rotation' -f `
        $bootstrapServerConfig, $mods, $activeMapPath, (Join-Path $projectRoot 'tests\fixtures\server-settings.json')
    $bootstrapServer = Start-Process -FilePath $FactorioExe -ArgumentList $bootstrapServerArgs -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $bootstrapServerLog -RedirectStandardError $bootstrapServerError
    $hostingDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $hostingDeadline) {
        if ($bootstrapServer.HasExited) { throw 'Endurance bootstrap server exited during startup.' }
        if ((Test-Path -LiteralPath $bootstrapServerLog) -and
            (Get-Content -LiteralPath $bootstrapServerLog -Raw -ErrorAction SilentlyContinue) -match 'Hosting game') { break }
        Start-Sleep -Milliseconds 250
    }
    if ([DateTime]::UtcNow -ge $hostingDeadline) { throw 'Endurance bootstrap server startup timed out.' }
    $bootstrapClientArgs = '--config "{0}" --mod-directory "{1}" --mp-connect 127.0.0.1:34621 --fullscreen=false --window-size 800x600 --disable-audio --no-log-rotation' -f `
        $bootstrapClientConfig, $mods
    $bootstrapClient = Start-Process -FilePath $FactorioExe -ArgumentList $bootstrapClientArgs -WindowStyle Minimized -PassThru `
        -RedirectStandardOutput $bootstrapClientLog -RedirectStandardError $bootstrapClientError
    $saveDeadline = [DateTime]::UtcNow.AddSeconds(90)
    while ([DateTime]::UtcNow -lt $saveDeadline -and -not (Test-Path -LiteralPath $playerMapPath)) {
        if ($bootstrapServer.HasExited) { throw 'Endurance bootstrap server exited before player save.' }
        if ($bootstrapClient.HasExited) { throw 'Endurance bootstrap client exited before player save.' }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path -LiteralPath $playerMapPath)) { throw 'Endurance bootstrap did not create a player save.' }
} finally {
    if ($bootstrapClient -and -not $bootstrapClient.HasExited) {
        Stop-Process -Id $bootstrapClient.Id -Force -ErrorAction SilentlyContinue
        $bootstrapClient.WaitForExit(5000) | Out-Null
    }
    if ($bootstrapServer -and -not $bootstrapServer.HasExited) {
        Stop-Process -Id $bootstrapServer.Id -Force -ErrorAction SilentlyContinue
        $bootstrapServer.WaitForExit(5000) | Out-Null
    }
}
$bootstrapDesync = Get-ChildItem -LiteralPath (Join-Path $bootstrapClientData 'archive') `
    -Filter 'desync-report-*.zip' -File -ErrorAction SilentlyContinue
if ($bootstrapDesync) { throw "Endurance bootstrap desync report created: $($bootstrapDesync[0].FullName)" }

$activeEvidencePath = Join-Path $writeData 'script-output\alina\megabase-endurance-alina.json'
if (Test-Path -LiteralPath $activeEvidencePath) { Remove-Item -LiteralPath $activeEvidencePath -Force }
$mapPath = $playerMapPath
# Benchmark mode is Factorio's deterministic, headless single-process runner. It
# unpauses a saved map by default and preserves the real player and physical
# Alina created by the bootstrap, so behavior and timing come from one run.
$enduranceSample = Invoke-Benchmark 'active-alina' $true $BenchmarkTicks
if (-not (Test-Path -LiteralPath $activeEvidencePath)) {
    throw 'Active Alina endurance evidence was not written.'
}
$alinaEvidence = Get-Content -LiteralPath $activeEvidencePath -Raw | ConvertFrom-Json
if ([int]$alinaEvidence.elapsed_ticks -lt ($BenchmarkTicks - 3600)) {
    throw "Active endurance evidence covered only $($alinaEvidence.elapsed_ticks) of $BenchmarkTicks ticks."
}
$alina = Invoke-Benchmark 'timing-alina' $true $TimingBenchmarkTicks
$baseline = Invoke-Benchmark 'baseline' $false $TimingBenchmarkTicks
$desyncReports = @($bootstrapDesync)

$added = $alina.AverageMs - $baseline.AverageMs
$tickBudgetPercent = 100 * $added / (1000 / 60)
$checks = [ordered]@{
    enough_entities = [int]$alinaEvidence.entity_count -ge $MinSyntheticEntities
    meaningful_production_entities = [int]$alinaEvidence.production_entities -ge 10000
    belts_are_connected_infrastructure = [int]$alinaEvidence.belt_entities -lt ([int]$alinaEvidence.entity_count * 0.85)
    k2so_max_tiers_selected = (-not $UseInstalledModPack) -or (
        [string]$alinaEvidence.selected_tiers.machine -match '^kr-' -and
        [string]$alinaEvidence.selected_tiers.belt -match '^kr-' -and
        [string]$alinaEvidence.selected_tiers.inserter -match '^kr-' -and
        [string]$alinaEvidence.selected_tiers.pole -match '^kr-' -and
        [string]$alinaEvidence.selected_tiers.drill -match '^kr-')
    fixture_has_real_output = [int]$alinaEvidence.max_working_machines -ge 100
    natural_iron_patch_command = $alinaEvidence.language_checks.iron.ok -eq $true -and
        $alinaEvidence.language_checks.iron.result -eq 'resource_chain_scheduled'
    natural_coal_patch_command = $alinaEvidence.language_checks.coal.ok -eq $true -and
        $alinaEvidence.language_checks.coal.result -eq 'resource_chain_scheduled'
    gui_is_fixed_size = [int]$alinaEvidence.gui_checks.panel_width -eq 520 -and
        [int]$alinaEvidence.gui_checks.panel_max_width -eq 520 -and
        [int]$alinaEvidence.gui_checks.panel_height -eq 250 -and
        [int]$alinaEvidence.gui_checks.panel_max_height -eq 250
    inventory_is_viewable = $alinaEvidence.gui_checks.inventory_opened -eq $true -and
        [int]$alinaEvidence.gui_checks.inventory_slots -gt 0
    development_mode_persisted = $alinaEvidence.development_focus -eq $true
    command_accepted = $alinaEvidence.request_sent -eq $true
    agent_present = $alinaEvidence.agent_present -eq $true -and [int]$alinaEvidence.agent_missing_samples -eq 0
    useful_work_completed = [int]$alinaEvidence.useful_completed_tasks -ge $MinUsefulCompletedTasks
    failures_bounded = [int]$alinaEvidence.failed_tasks -le $MaxFailedTasks
    current_task_not_stuck = [int]$alinaEvidence.current_task_age_ticks -le $MaxCurrentTaskAgeTicks
    world_model_active = [int]$alinaEvidence.max_indexed_entities -ge 1000 -and [int]$alinaEvidence.max_scanned_chunks -gt 0
    baseline_within_60_ups = $baseline.AverageMs -le $MaxAverageMillisecondsPerTick
    alina_within_60_ups = $alina.AverageMs -le $MaxAverageMillisecondsPerTick
    alina_added_cost_within_budget = $added -le $MaxAddedMillisecondsPerTick
    active_has_no_long_update_stall = $enduranceSample.MaximumMs -le $MaxUpdateMilliseconds
    timing_has_no_long_update_stall = $alina.MaximumMs -le $MaxUpdateMilliseconds
}
$ok = @($checks.Values | Where-Object { $_ -ne $true }).Count -eq 0
$result = [ordered]@{
    ok = $ok
    synthetic_entities = [int]$alinaEvidence.entity_count
    production_cells = [int]$alinaEvidence.production_cells
    production_entities = [int]$alinaEvidence.production_entities
    belt_entities = [int]$alinaEvidence.belt_entities
    selected_tiers = $alinaEvidence.selected_tiers
    max_working_machines = [int]$alinaEvidence.max_working_machines
    language_checks = $alinaEvidence.language_checks
    gui_checks = $alinaEvidence.gui_checks
    benchmark_ticks = $BenchmarkTicks
    timing_benchmark_ticks = $TimingBenchmarkTicks
    simulated_minutes = [math]::Round($BenchmarkTicks / 3600, 1)
    baseline_average_ms = [math]::Round($baseline.AverageMs, 4)
    alina_average_ms = [math]::Round($alina.AverageMs, 4)
    endurance_average_ms = [math]::Round($enduranceSample.AverageMs, 4)
    endurance_maximum_ms = [math]::Round($enduranceSample.MaximumMs, 4)
    alina_timing_maximum_ms = [math]::Round($alina.MaximumMs, 4)
    added_ms_per_tick = [math]::Round($added, 4)
    added_percent_of_60_ups_budget = [math]::Round($tickBudgetPercent, 3)
    useful_completed_tasks = [int]$alinaEvidence.useful_completed_tasks
    completed_tasks = [int]$alinaEvidence.completed_tasks
    failed_tasks = [int]$alinaEvidence.failed_tasks
    current_task = $alinaEvidence.current_task
    current_task_age_ticks = [int]$alinaEvidence.current_task_age_ticks
    max_task_age_ticks = [int]$alinaEvidence.max_task_age_ticks
    indexed_entities = [int]$alinaEvidence.max_indexed_entities
    scanned_chunks = [int]$alinaEvidence.max_scanned_chunks
    autonomy_actions = [int]$alinaEvidence.autonomy_actions
    checks = $checks
    task_results = $alinaEvidence.tasks
    desync_reports = $desyncReports.Count
    output = $testRoot
}
$resultPath = Join-Path $testRoot 'result.json'
[System.IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json -Depth 8
if (-not $ok) { throw "Megabase endurance test failed. See $resultPath" }
