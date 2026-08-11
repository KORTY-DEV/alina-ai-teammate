[CmdletBinding()]
param(
    [switch]$IncludeOllama,
    [string]$FactorioExe,
    [string]$SecondFactorioExe
)

$ErrorActionPreference = 'Stop'

if ($env:OS -eq 'Windows_NT') {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AlinaWindowControl {
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
'@
}

function Hide-AlinaTestWindow([System.Diagnostics.Process]$Process) {
    if ($env:OS -ne 'Windows_NT' -or -not $Process) { return }
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        if ($Process.HasExited) { return }
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            [AlinaWindowControl]::ShowWindowAsync($Process.MainWindowHandle, 0) | Out-Null
            return
        }
        Start-Sleep -Milliseconds 50
    }
}

function Wait-PhysicalClientInGame(
    [System.Diagnostics.Process]$Client,
    [System.Diagnostics.Process]$Server,
    [string]$ServerLog,
    [string]$ClientLog,
    [int]$MinimumInGameTransitions,
    [int]$TimeoutSeconds = 120
) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Server.HasExited) { throw 'Physical expansion server exited while a client was joining.' }
        if ($Client.HasExited) { throw 'Physical expansion client exited while joining.' }
        $clientText = if (Test-Path -LiteralPath $ClientLog) {
            Get-Content -LiteralPath $ClientLog -Raw -ErrorAction SilentlyContinue
        } else { '' }
        if ($clientText -match 'Connection refused|Could not establish network communication|MultiplayerManager failed') {
            throw "Physical expansion client failed to join: $($Matches[0])."
        }
        $serverText = if (Test-Path -LiteralPath $ServerLog) {
            Get-Content -LiteralPath $ServerLog -Raw -ErrorAction SilentlyContinue
        } else { '' }
        $inGame = ([regex]::Matches($serverText, 'newState\(InGame\)')).Count
        if ($inGame -ge $MinimumInGameTransitions) { return $inGame }
        Start-Sleep -Milliseconds 250
    }
    throw "Physical client did not reach InGame; expected transition $MinimumInGameTransitions."
}

function New-IsolatedFactorioClientExecutable(
    [string]$SourceExe,
    [string]$Destination,
    [string]$TestUserName,
    [int]$TestAccountId,
    [int]$TestAppId
) {
    $sourceDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $SourceExe))
    $destinationDirectory = [IO.Path]::GetFullPath($Destination)
    if (Test-Path -LiteralPath $destinationDirectory) {
        Remove-Item -LiteralPath $destinationDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $sourceDirectory -File | Where-Object Extension -ne '.pdb' |
        Copy-Item -Destination $destinationDirectory -Force

    # Some portable builds derive the multiplayer identity from a local Steam
    # emulator file instead of player-data.json. Configure only the disposable
    # test copy; an official build without this file is left untouched.
    $emulator = Join-Path $destinationDirectory 'steam_emu.ini'
    if (Test-Path -LiteralPath $emulator) {
        $text = [IO.File]::ReadAllText($emulator)
        $text = [regex]::Replace($text, '(?m)^AppId=.*$', "AppId=$TestAppId")
        $text = [regex]::Replace($text, '(?m)^UserName=.*$', "UserName=$TestUserName")
        $text = [regex]::Replace($text, '(?m)^#?AccountId=.*$', "AccountId=$TestAccountId")
        $text = [regex]::Replace($text, '(?m)^Offline=.*$', 'Offline=1')
        $text = [regex]::Replace($text, '(?m)^LobbyEnabled=.*$', 'LobbyEnabled=0')
        $text = [regex]::Replace($text, '(?m)^Overlays=.*$', 'Overlays=0')
        [IO.File]::WriteAllText($emulator, $text, [Text.UTF8Encoding]::new($false))
    }
    $result = Join-Path $destinationDirectory (Split-Path -Leaf $SourceExe)
    if (-not (Test-Path -LiteralPath $result)) { throw "Isolated Factorio client is missing: $result" }
    return $result
}
$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot '.test-output'))

if (-not $testRoot.StartsWith($projectRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unsafe test output path.'
}

if (-not $FactorioExe) {
    $candidates = @(
        'D:\Games\Factorio Space Age v2.1.12b\Factorio Space Age v2.1.12b\bin\x64\factorio.exe',
        'C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe'
    )
    $FactorioExe = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $FactorioExe -or -not (Test-Path -LiteralPath $FactorioExe)) {
    throw 'Factorio executable not found. Pass -FactorioExe explicitly.'
}
if (-not $SecondFactorioExe) { $SecondFactorioExe = $FactorioExe }

Write-Output '=== .NET build ==='
& dotnet build (Join-Path $projectRoot 'bridge\Alina.Bridge.Tests\Alina.Bridge.Tests.csproj') --configuration Release
if ($LASTEXITCODE -ne 0) { throw 'Bridge build failed.' }

Write-Output '=== Contract tests ==='
& dotnet run --project (Join-Path $projectRoot 'bridge\Alina.Bridge.Tests\Alina.Bridge.Tests.csproj') --configuration Release --no-build
if ($LASTEXITCODE -ne 0) { throw 'Contract tests failed.' }

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$testMods = Join-Path $testRoot 'mods'
if (Test-Path -LiteralPath $testMods) {
    $resolved = [System.IO.Path]::GetFullPath($testMods)
    if (-not $resolved.StartsWith($testRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe temporary mods path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
New-Item -ItemType Directory -Path $testMods -Force | Out-Null

$modSource = Join-Path $projectRoot 'factorio-mod\alina-ai-teammate_0.1.0'
Copy-Item -LiteralPath $modSource -Destination (Join-Path $testMods 'alina-ai-teammate_0.1.0') -Recurse
$modList = @{
    mods = @(
        @{ name = 'base'; enabled = $true },
        @{ name = 'elevated-rails'; enabled = $true },
        @{ name = 'quality'; enabled = $true },
        @{ name = 'recycler'; enabled = $true },
        @{ name = 'space-age'; enabled = $true },
        @{ name = 'alina-ai-teammate'; enabled = $true }
    )
} | ConvertTo-Json -Depth 4
Set-Content -LiteralPath (Join-Path $testMods 'mod-list.json') -Value $modList -Encoding UTF8

$factorioInstall = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $FactorioExe))))
$readData = Join-Path $factorioInstall 'data'
$writeData = Join-Path $testRoot 'factorio-user-data'
New-Item -ItemType Directory -Path $writeData -Force | Out-Null
$configPath = Join-Path $testRoot 'factorio-test.ini'
$config = "[path]`r`nread-data=$readData`r`nwrite-data=$writeData`r`n"
Set-Content -LiteralPath $configPath -Value $config -Encoding UTF8

$mapPath = Join-Path $testRoot 'alina-test.zip'
if (Test-Path -LiteralPath $mapPath) {
    $resolvedMap = [System.IO.Path]::GetFullPath($mapPath)
    if (-not $resolvedMap.StartsWith($testRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe temporary map path.'
    }
    Remove-Item -LiteralPath $resolvedMap -Force
}
$createArgs = '--config "{0}" --mod-directory "{1}" --create "{2}" --map-gen-seed 424242 --no-log-rotation' -f $configPath, $testMods, $mapPath
Write-Output '=== Factorio isolated create ==='
$create = Start-Process -FilePath $FactorioExe -ArgumentList $createArgs -WindowStyle Hidden -Wait -PassThru
if ($create.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $mapPath)) {
    throw "Factorio map creation failed with exit code $($create.ExitCode)."
}

$benchmarkArgs = '--config "{0}" --mod-directory "{1}" --benchmark "{2}" --benchmark-ticks 120 --benchmark-runs 1 --no-log-rotation' -f $configPath, $testMods, $mapPath
Write-Output '=== Factorio isolated benchmark ==='
$benchmark = Start-Process -FilePath $FactorioExe -ArgumentList $benchmarkArgs -WindowStyle Hidden -Wait -PassThru
if ($benchmark.ExitCode -ne 0) { throw "Factorio benchmark failed with exit code $($benchmark.ExitCode)." }

Write-Output '=== Physical connected-module expansion E2E ==='
$physicalTestMod = Join-Path $projectRoot 'tests\fixtures\alina-physical-expansion-test_0.1.0'
if (-not (Test-Path -LiteralPath (Join-Path $physicalTestMod 'info.json'))) {
    throw 'Physical expansion fixture mod is missing.'
}
Copy-Item -LiteralPath $physicalTestMod -Destination (Join-Path $testMods 'alina-physical-expansion-test_0.1.0') -Recurse -Force
$modListObject = Get-Content -LiteralPath (Join-Path $testMods 'mod-list.json') -Raw | ConvertFrom-Json
$modListObject.mods = @($modListObject.mods) + @(
    [pscustomobject]@{ name = 'alina-physical-expansion-test'; enabled = $true }
)
[System.IO.File]::WriteAllText(
    (Join-Path $testMods 'mod-list.json'),
    ($modListObject | ConvertTo-Json -Depth 5),
    [Text.UTF8Encoding]::new($false))

$physicalMap = Join-Path $testRoot 'alina-physical-expansion-test.zip'
$physicalResult = Join-Path $writeData 'script-output\alina\physical-expansion-result.json'
foreach ($path in @($physicalMap, $physicalResult)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}
$physicalCreateArgs = '--config "{0}" --mod-directory "{1}" --create "{2}" --map-gen-seed 989898 --no-log-rotation' -f $configPath, $testMods, $physicalMap
$physicalCreate = Start-Process -FilePath $FactorioExe -ArgumentList $physicalCreateArgs -WindowStyle Hidden -Wait -PassThru
if ($physicalCreate.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $physicalMap)) {
    throw "Physical expansion map creation failed with exit code $($physicalCreate.ExitCode)."
}
$physicalServerData = Join-Path $testRoot 'physical-server-data'
$physicalClientData = Join-Path $testRoot 'physical-client-data'
$physicalClientData2 = Join-Path $testRoot 'physical-client-data-2'
foreach ($isolatedData in @($physicalServerData, $physicalClientData, $physicalClientData2)) {
    if (Test-Path -LiteralPath $isolatedData) {
        $resolvedData = [System.IO.Path]::GetFullPath($isolatedData)
        if (-not $resolvedData.StartsWith($testRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Unsafe physical test data path.'
        }
        Remove-Item -LiteralPath $resolvedData -Recurse -Force
    }
}
New-Item -ItemType Directory -Path $physicalServerData, $physicalClientData, $physicalClientData2 -Force | Out-Null
$testPlayerData1 = @{ 'service-username' = 'alina-crc-client-1'; 'service-token' = '' } | ConvertTo-Json
$testPlayerData2 = @{ 'service-username' = 'alina-crc-client-2'; 'service-token' = '' } | ConvertTo-Json
[System.IO.File]::WriteAllText((Join-Path $physicalClientData 'player-data.json'), $testPlayerData1,
    [Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $physicalClientData2 'player-data.json'), $testPlayerData2,
    [Text.UTF8Encoding]::new($false))
$physicalServerConfig = Join-Path $testRoot 'physical-server.ini'
$physicalClientConfig = Join-Path $testRoot 'physical-client.ini'
$physicalClientConfig2 = Join-Path $testRoot 'physical-client-2.ini'
Set-Content -LiteralPath $physicalServerConfig -Encoding UTF8 -Value "[path]`r`nread-data=$readData`r`nwrite-data=$physicalServerData`r`n"
$physicalClientConfigText = "[path]`r`nread-data=$readData`r`nwrite-data=$physicalClientData`r`n`r`n[other]`r`nfactorio-username=alina-crc-client-1`r`n`r`n[graphics]`r`ngraphics-quality=low`r`nvideo-memory-usage=low`r`ntexture-streaming=true`r`nv-sync=false`r`n"
Set-Content -LiteralPath $physicalClientConfig -Encoding UTF8 -Value $physicalClientConfigText
Set-Content -LiteralPath $physicalClientConfig2 -Encoding UTF8 -Value ($physicalClientConfigText.Replace(
    "write-data=$physicalClientData", "write-data=$physicalClientData2").Replace(
    'factorio-username=alina-crc-client-1', 'factorio-username=alina-crc-client-2'))
$physicalResult = Join-Path $physicalServerData 'script-output\alina\physical-expansion-result.json'
if (Test-Path -LiteralPath $physicalResult) { Remove-Item -LiteralPath $physicalResult -Force }
$physicalServerLog = Join-Path $testRoot 'physical-server.stdout.log'
$physicalServerError = Join-Path $testRoot 'physical-server.stderr.log'
Remove-Item -LiteralPath $physicalServerLog, $physicalServerError -Force -ErrorAction SilentlyContinue
$physicalGamePort = 34617
$physicalSteamStorageRoot = [IO.Path]::GetFullPath('C:\Users\Public\Documents\Steam\RUNE')
$physicalSteamStorageCleanup = @()
foreach ($testAppId in @(427521, 427522)) {
    $candidate = [IO.Path]::GetFullPath((Join-Path $physicalSteamStorageRoot ([string]$testAppId)))
    if (-not (Test-Path -LiteralPath $candidate)) {
        $physicalSteamStorageCleanup += $candidate
        continue
    }
    # Recover only the exact empty profiles left by an interrupted earlier
    # Alina run. Never claim a profile containing saves or unknown files.
    $profileFiles = @(Get-ChildItem -LiteralPath $candidate -Recurse -File -ErrorAction SilentlyContinue)
    $profileDirs = @(Get-ChildItem -LiteralPath $candidate -Recurse -Directory -ErrorAction SilentlyContinue)
    $expectedNames = @($profileFiles | ForEach-Object Name | Sort-Object)
    $unexpectedDirs = @($profileDirs | Where-Object {
        $_.Name -notin @('local', 'remote') -or
        @(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue).Count -gt 0
    })
    if ($unexpectedDirs.Count -eq 0 -and $expectedNames.Count -eq 2 `
            -and $expectedNames[0] -eq 'achievements.ini' `
            -and $expectedNames[1] -eq 'leaderboards.ini' `
            -and (Get-Content -LiteralPath $profileFiles[0].FullName -Raw) -match '^\[Steam(Achievements|Leaderboards)\]\r?\nCount=0\s*$' `
            -and (Get-Content -LiteralPath $profileFiles[1].FullName -Raw) -match '^\[Steam(Achievements|Leaderboards)\]\r?\nCount=0\s*$') {
        $physicalSteamStorageCleanup += $candidate
    }
}
$physicalClientExe1 = New-IsolatedFactorioClientExecutable -SourceExe $FactorioExe `
    -Destination (Join-Path $testRoot 'physical-client-bin-1') `
    -TestUserName 'alina-crc-client-1' -TestAccountId 310001 -TestAppId 427521
$physicalClientExe2 = if ($SecondFactorioExe) {
    New-IsolatedFactorioClientExecutable -SourceExe $SecondFactorioExe `
        -Destination (Join-Path $testRoot 'physical-client-bin-2') `
        -TestUserName 'alina-crc-client-2' -TestAccountId 310002 -TestAppId 427522
} else { $null }
$physicalServer = $null
$physicalClient = $null
$physicalClient2 = $null
$physicalClient2Rejoined = $false
try {
    $serverArgs = '--config "{0}" --mod-directory "{1}" --start-server "{2}" --bind 127.0.0.1:{3} --server-settings "{4}" --no-log-rotation' -f `
        $physicalServerConfig, $testMods, $physicalMap, $physicalGamePort, (Join-Path $projectRoot 'tests\fixtures\server-settings.json')
    $physicalServer = Start-Process -FilePath $FactorioExe -ArgumentList $serverArgs -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $physicalServerLog -RedirectStandardError $physicalServerError
    $serverDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $serverDeadline) {
        if ($physicalServer.HasExited) { throw 'Physical expansion test server exited during startup.' }
        if ((Test-Path -LiteralPath $physicalServerLog) -and
            (Get-Content -LiteralPath $physicalServerLog -Raw -ErrorAction SilentlyContinue) -match 'Hosting game') { break }
        Start-Sleep -Milliseconds 250
    }
    if ([DateTime]::UtcNow -ge $serverDeadline) { throw 'Physical expansion test server startup timed out.' }

    $clientArgs = '--config "{0}" --mod-directory "{1}" --mp-connect 127.0.0.1:{2} --fullscreen=false --window-size 800x600 --disable-audio --no-log-rotation' -f `
        $physicalClientConfig, $testMods, $physicalGamePort
    $physicalClient = Start-Process -FilePath $physicalClientExe1 -ArgumentList $clientArgs -WindowStyle Minimized -PassThru
    Hide-AlinaTestWindow $physicalClient
    Wait-PhysicalClientInGame -Client $physicalClient -Server $physicalServer `
        -ServerLog $physicalServerLog `
        -ClientLog (Join-Path $physicalClientData 'factorio-current.log') `
        -MinimumInGameTransitions 1 | Out-Null
    if ($SecondFactorioExe) {
        if (-not (Test-Path -LiteralPath $SecondFactorioExe)) {
            throw 'Second Factorio client executable was not found.'
        }
        $clientArgs2 = '--config "{0}" --mod-directory "{1}" --mp-connect 127.0.0.1:{2} --fullscreen=false --window-size 800x600 --disable-audio --no-log-rotation' -f `
            $physicalClientConfig2, $testMods, $physicalGamePort
        $physicalClient2 = Start-Process -FilePath $physicalClientExe2 -ArgumentList $clientArgs2 -WindowStyle Minimized -PassThru
        Hide-AlinaTestWindow $physicalClient2
        Wait-PhysicalClientInGame -Client $physicalClient2 -Server $physicalServer `
            -ServerLog $physicalServerLog `
            -ClientLog (Join-Path $physicalClientData2 'factorio-current.log') `
            -MinimumInGameTransitions 2 | Out-Null

        # A process remaining open can mean Factorio fell back to the main
        # menu after Connection refused. Force a real leave/rejoin cycle and
        # accept the gate only after a third server-side InGame transition.
        Stop-Process -Id $physicalClient2.Id -Force -ErrorAction Stop
        $physicalClient2.WaitForExit(10000) | Out-Null
        Start-Sleep -Seconds 2
        $physicalClient2 = Start-Process -FilePath $physicalClientExe2 -ArgumentList $clientArgs2 -WindowStyle Minimized -PassThru
        Hide-AlinaTestWindow $physicalClient2
        Wait-PhysicalClientInGame -Client $physicalClient2 -Server $physicalServer `
            -ServerLog $physicalServerLog `
            -ClientLog (Join-Path $physicalClientData2 'factorio-current.log') `
            -MinimumInGameTransitions 3 | Out-Null
        $physicalClient2Rejoined = $true
    }
    $resultDeadline = [DateTime]::UtcNow.AddSeconds(420)
    while ([DateTime]::UtcNow -lt $resultDeadline -and -not (Test-Path -LiteralPath $physicalResult)) {
        if ($physicalServer.HasExited) { throw 'Physical expansion test server exited before verification.' }
        if ($physicalClient.HasExited) { throw 'Physical expansion test client exited before verification.' }
        if ($physicalClient2 -and $physicalClient2.HasExited) { throw 'Second CRC client exited before verification.' }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path -LiteralPath $physicalResult)) {
        throw 'Physical expansion did not produce a verified result before timeout.'
    }
} finally {
    if ($physicalClient2 -and -not $physicalClient2.HasExited) {
        Stop-Process -Id $physicalClient2.Id -Force -ErrorAction SilentlyContinue
        $physicalClient2.WaitForExit(5000) | Out-Null
    }
    if ($physicalClient -and -not $physicalClient.HasExited) {
        Stop-Process -Id $physicalClient.Id -Force -ErrorAction SilentlyContinue
        $physicalClient.WaitForExit(5000) | Out-Null
    }
    if ($physicalServer -and -not $physicalServer.HasExited) {
        Stop-Process -Id $physicalServer.Id -Force -ErrorAction SilentlyContinue
        $physicalServer.WaitForExit(5000) | Out-Null
    }
    foreach ($testStorage in $physicalSteamStorageCleanup) {
        $resolvedStorage = [IO.Path]::GetFullPath($testStorage)
        if ($resolvedStorage.StartsWith($physicalSteamStorageRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase) `
                -and (Split-Path -Leaf $resolvedStorage) -in @('427521', '427522') `
                -and (Test-Path -LiteralPath $resolvedStorage)) {
            Remove-Item -LiteralPath $resolvedStorage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # A portable Steam shim can flush its two empty bookkeeping directories a
    # fraction after Factorio exits. Retry only the profiles proven disposable
    # above, then fail rather than leave test data outside the workspace.
    foreach ($testStorage in $physicalSteamStorageCleanup) {
        $resolvedStorage = [IO.Path]::GetFullPath($testStorage)
        for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $resolvedStorage); $attempt++) {
            Start-Sleep -Milliseconds 100
            Remove-Item -LiteralPath $resolvedStorage -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $resolvedStorage) {
            throw "Disposable multiplayer profile was not removed: $resolvedStorage"
        }
    }
}
$physicalResultJson = Get-Content -LiteralPath $physicalResult -Raw | ConvertFrom-Json
$desyncReports = @(
    Get-ChildItem -LiteralPath (Join-Path $physicalClientData 'archive') `
        -Filter 'desync-report-*.zip' -File -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath (Join-Path $physicalClientData2 'archive') `
        -Filter 'desync-report-*.zip' -File -ErrorAction SilentlyContinue
)
if ($desyncReports.Count -gt 0) {
    throw "Multiplayer desync report created: $($desyncReports[0].FullName)"
}
if ($SecondFactorioExe -and -not $physicalClient2Rejoined) {
    throw 'Second physical client did not complete the required join/rejoin cycle.'
}
if (-not $physicalResultJson.ok -or $physicalResultJson.ghosts -ne 0 -or $physicalResultJson.output -lt 1 `
        -or $physicalResultJson.mined_and_delivered -lt 25 -or -not $physicalResultJson.mining_drill_expanded `
        -or $physicalResultJson.mining_products_finished -lt 1 -or -not $physicalResultJson.power_restored `
        -or $physicalResultJson.power_poles_built -lt 1 -or $physicalResultJson.bootstrap_chain_output -lt 1 `
        -or $physicalResultJson.bootstrap_drills -lt 2 -or $physicalResultJson.bootstrap_furnaces -lt 2 `
        -or $physicalResultJson.bootstrap_belts -lt 12 `
        -or ($physicalResultJson.loadout_armor -ne 'light-armor' -and $physicalResultJson.loadout_armor -ne 'modular-armor') `
        -or $physicalResultJson.loadout_gun -ne 'pistol' -or $physicalResultJson.loadout_ammo -lt 50 `
        -or $physicalResultJson.assembly_machines -lt 4 -or $physicalResultJson.assembly_output -lt 1 `
        -or $physicalResultJson.assembly_build_events -lt 24 `
        -or $physicalResultJson.assembly_vertical_reversals -gt 2 `
        -or $physicalResultJson.assembly_compact_row_machines -lt 4 `
        -or $physicalResultJson.assembly_max_machine_gap -gt 1.01 `
        -or -not $physicalResultJson.marker_understood -or -not $physicalResultJson.research_indefinite_hold `
        -or -not $physicalResultJson.research_timed_hold -or -not $physicalResultJson.player_research_preserved `
        -or -not $physicalResultJson.research_priority_followed -or -not $physicalResultJson.autonomous_research `
        -or $physicalResultJson.advanced_machines -lt 8 -or $physicalResultJson.advanced_speed_modules -lt 8 `
        -or $physicalResultJson.advanced_requesters -lt 8 -or $physicalResultJson.advanced_providers -lt 8 `
        -or $physicalResultJson.advanced_output -lt 1 -or $physicalResultJson.long_route_belts -lt 80 `
        -or $physicalResultJson.long_route_output -lt 1 -or $physicalResultJson.long_route_output_distance -gt 16 `
        -or $physicalResultJson.mobility_armor -ne 'modular-armor' `
        -or $physicalResultJson.mobility_burner_generator -lt 1 -or $physicalResultJson.mobility_fuel_refill -lt 9 `
        -or $physicalResultJson.mobility_belt_immunity -lt 1 `
        -or $physicalResultJson.mobility_exoskeleton -lt 1 -or $physicalResultJson.mobility_spider_routes -lt 1 `
        -or $physicalResultJson.mobility_spider_fallbacks -ne 0 `
        -or $physicalResultJson.mobility_mined_and_delivered -lt 10 `
        -or -not $physicalResultJson.machine_upgrade_verified `
        -or -not $physicalResultJson.machine_upgrade_rollback `
        -or -not $physicalResultJson.upstream_pressure_verified `
        -or -not $physicalResultJson.logistics_pressure_verified `
        -or -not $physicalResultJson.active_player_boundary_verified `
        -or -not $physicalResultJson.protected_area_owner_verified `
        -or -not $physicalResultJson.protected_area_release_verified `
        -or -not $physicalResultJson.periodic_advice_generated) {
    throw "Physical expansion verification failed: $($physicalResultJson | ConvertTo-Json -Compress)"
}
Write-Output "Two physical clients plus a forced leave/rejoin, direct mining, physical expansion, power repair, compact lane-swept marker production, research control, loadout, robot-fed 8-machine production, long belt routing, burner-equipment refill, an owned Spidertron route, verified in-place upgrading, automatic rollback, upstream-versus-logistics pressure classification, cross-cell player activity, owned protected-area release, and cached periodic advice were verified."

$factorioLog = Join-Path $writeData 'factorio-current.log'
if (Test-Path -LiteralPath $factorioLog) {
    $modErrors = Select-String -LiteralPath $factorioLog -Pattern 'Error.*alina|__alina-ai-teammate__.*Error|LuaError' -ErrorAction SilentlyContinue
    if ($modErrors) { throw ($modErrors | ForEach-Object Line | Out-String) }
}

if ($IncludeOllama) {
    Write-Output '=== Ollama structured-output self-test ==='
    & dotnet run --project (Join-Path $projectRoot 'bridge\Alina.Bridge') --configuration Release --no-build -- --self-test --config (Join-Path $projectRoot 'bridge\appsettings.example.json')
    if ($LASTEXITCODE -ne 0) { throw 'Ollama self-test failed.' }
}

Write-Output 'PROJECT TESTS OK'
