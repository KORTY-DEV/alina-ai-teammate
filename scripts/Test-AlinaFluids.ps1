[CmdletBinding()]
param([string]$FactorioExe)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot '.test-output\fluid-production'))
if (-not $testRoot.StartsWith($projectRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fluid test path.' }
if (-not $FactorioExe) {
    $FactorioExe = @(
        'D:\Games\Factorio Space Age v2.1.12b\Factorio Space Age v2.1.12b\bin\x64\factorio.exe',
        'C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe'
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $FactorioExe -or -not (Test-Path -LiteralPath $FactorioExe)) { throw 'Factorio executable not found.' }

if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
$mods = Join-Path $testRoot 'mods'
$writeData = Join-Path $testRoot 'write-data'
New-Item -ItemType Directory -Path $mods, $writeData -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'factorio-mod\alina-ai-teammate_0.1.0') `
    -Destination (Join-Path $mods 'alina-ai-teammate_0.1.0') -Recurse
Copy-Item -LiteralPath (Join-Path $projectRoot 'tests\fixtures\alina-fluid-production-test_0.1.0') `
    -Destination (Join-Path $mods 'alina-fluid-production-test_0.1.0') -Recurse
@{ mods = @(
        @{ name = 'base'; enabled = $true },
        @{ name = 'alina-ai-teammate'; enabled = $true },
        @{ name = 'alina-fluid-production-test'; enabled = $true }
    ) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $mods 'mod-list.json') -Encoding UTF8

$installRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $FactorioExe))))
$configPath = Join-Path $testRoot 'config.ini'
"[path]`r`nread-data=$(Join-Path $installRoot 'data')`r`nwrite-data=$writeData`r`n" |
    Set-Content -LiteralPath $configPath -Encoding UTF8
$save = Join-Path $testRoot 'fluid-production.zip'
$createArgs = '--config "{0}" --mod-directory "{1}" --create "{2}" --map-gen-seed 515151 --no-log-rotation' `
    -f $configPath, $mods, $save
$create = Start-Process -FilePath $FactorioExe -ArgumentList $createArgs -WindowStyle Hidden -Wait -PassThru
if ($create.ExitCode -ne 0) { throw "Fluid test map creation failed: $($create.ExitCode)" }

$serverData = Join-Path $testRoot 'server-data'
$clientData = Join-Path $testRoot 'client-data'
New-Item -ItemType Directory -Path $serverData, $clientData -Force | Out-Null
@{ 'service-username' = 'alina-fluid-client'; 'service-token' = '' } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $clientData 'player-data.json') -Encoding UTF8
$serverConfig = Join-Path $testRoot 'server.ini'
$clientConfig = Join-Path $testRoot 'client.ini'
"[path]`r`nread-data=$(Join-Path $installRoot 'data')`r`nwrite-data=$serverData`r`n" |
    Set-Content -LiteralPath $serverConfig -Encoding UTF8
"[path]`r`nread-data=$(Join-Path $installRoot 'data')`r`nwrite-data=$clientData`r`n`r`n[other]`r`nfactorio-username=alina-fluid-client`r`n`r`n[graphics]`r`ngraphics-quality=low`r`nvideo-memory-usage=low`r`ntexture-streaming=true`r`nv-sync=false`r`n" |
    Set-Content -LiteralPath $clientConfig -Encoding UTF8
$resultPath = Join-Path $serverData 'script-output\alina\fluid-production-result.json'
$telemetryPath = Join-Path $serverData 'script-output\alina\events.jsonl'
$serverLog = Join-Path $testRoot 'server.stdout.log'
$serverError = Join-Path $testRoot 'server.stderr.log'
$server = $null
$client = $null
try {
    $serverArgs = '--config "{0}" --mod-directory "{1}" --start-server "{2}" --bind 127.0.0.1:34619 --server-settings "{3}" --no-log-rotation' `
        -f $serverConfig, $mods, $save, (Join-Path $projectRoot 'tests\fixtures\server-settings.json')
    $server = Start-Process -FilePath $FactorioExe -ArgumentList $serverArgs -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $serverLog -RedirectStandardError $serverError
    $startupDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $startupDeadline) {
        if ($server.HasExited) { throw 'Fluid test server exited during startup.' }
        if ((Test-Path -LiteralPath $serverLog) -and
            (Get-Content -LiteralPath $serverLog -Raw -ErrorAction SilentlyContinue) -match 'Hosting game') { break }
        Start-Sleep -Milliseconds 250
    }
    if ([DateTime]::UtcNow -ge $startupDeadline) { throw 'Fluid test server startup timed out.' }
    $clientArgs = '--config "{0}" --mod-directory "{1}" --mp-connect 127.0.0.1:34619 --fullscreen=false --window-size 800x600 --disable-audio --no-log-rotation' `
        -f $clientConfig, $mods
    $client = Start-Process -FilePath $FactorioExe -ArgumentList $clientArgs -WindowStyle Minimized -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(240)
    $lastProgress = [DateTime]::UtcNow
    $lastTelemetryLength = 0L
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $resultPath)) {
        if ($server.HasExited) { throw 'Fluid test server exited before verification.' }
        if ($client.HasExited) { throw 'Fluid test client exited before verification.' }
        if (Test-Path -LiteralPath $telemetryPath) {
            $telemetryLength = (Get-Item -LiteralPath $telemetryPath).Length
            if ($telemetryLength -gt $lastTelemetryLength) {
                $lastTelemetryLength = $telemetryLength
                $lastProgress = [DateTime]::UtcNow
            } elseif (([DateTime]::UtcNow - $lastProgress).TotalSeconds -gt 75) {
                Get-Content -LiteralPath $telemetryPath -Tail 30 -ErrorAction SilentlyContinue
                throw 'Fluid test made no observable progress for 75 seconds.'
            }
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path -LiteralPath $resultPath)) {
        if (Test-Path -LiteralPath $serverLog) { Get-Content -LiteralPath $serverLog -Tail 120 }
        throw 'Fluid test did not produce a result.'
    }
} finally {
    if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue }
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
}
$desync = Get-ChildItem -LiteralPath (Join-Path $clientData 'archive') -Filter 'desync-report-*.zip' `
    -File -ErrorAction SilentlyContinue
if ($desync) { throw "Fluid multiplayer desync report created: $($desync[0].FullName)" }
$result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
if (-not $result.ok -or $result.machines -lt 4 -or $result.pipes -lt 1 -or $result.product -lt 1 `
        -or $result.pumps -lt 1 -or $result.powered_pumps -ne $result.pumps `
        -or $result.heavy_oil -le 0 -or $result.light_oil -le 0 `
        -or $result.refineries -lt 4 -or $result.source_drills -lt 1 -or -not $result.crude_extracted `
        -or -not $result.petroleum_upstream_working -or -not $result.water_source_preserved `
        -or $result.connected_players -lt 1) {
    throw "Fluid test result failed: $(Get-Content -Raw -LiteralPath $resultPath)"
}
Write-Output ("FLUID PRODUCTION TEST OK: wells={8}, refineries={9}, machines={0}, pipes={1}, pumps={2}/{3} powered, product={4}, heavy={5}, light={6}, tick={7}" -f `
    $result.machines, $result.pipes, $result.powered_pumps, $result.pumps, $result.product, `
    $result.heavy_oil, $result.light_oil, $result.tick, $result.source_drills, $result.refineries)
Write-Output ("Evidence: {0}" -f $resultPath)
