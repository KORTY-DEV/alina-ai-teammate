[CmdletBinding()]
param(
    [string]$FactorioExe,
    [int]$TimeoutSeconds = 150
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot '.test-output\vertical-mvp'))
$baseTestRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot '.test-output'))
$gamePort = 34297
$rconPort = 34298
$rconPassword = 'alina-isolated-e2e'
$chatMessage = [System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String('0JDQu9GPLCDQtNC+0LHRg9C00Ywg0LbQtdC70LXQt9Cw'))
$shortageMessage = [System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String('0JDQu9C40L3QsCwg0LbQtdC70LXQt9CwINC90LUg0YXQstCw0YLQsNC10YIsINGA0LDQt9Cx0LXRgNC40YHRjA=='))
$maintenanceMessage = [System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String('0JDQu9C40L3QsCwg0LzQtdC00L3Ri9GFINC/0LvQuNGCINGB0L3QvtCy0LAg0L3QtSDRhdCy0LDRgtCw0LXRgiwg0YDQsNC30LHQtdGA0LjRgdGM'))
$processes = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$previousPassword = $env:ALINA_RCON_PASSWORD

function Assert-UnderTestRoot([string]$Path) {
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($baseTestRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe E2E path: $resolved"
    }
    return $resolved
}

function Invoke-Rcon([string]$Command) {
    $output = & dotnet $script:bridgeDll --config $script:bridgeConfig --rcon-command $Command 2>&1
    if ($LASTEXITCODE -ne 0) { throw "RCON command failed: $($output -join [Environment]::NewLine)" }
    return ($output -join [Environment]::NewLine).Trim()
}

function Wait-RconReply([string]$Command, [string]$Pattern, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $lastError = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $reply = Invoke-Rcon $Command
            if ($reply -match $Pattern) { return $reply }
            $lastError = "Unexpected reply: $reply"
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 300
    }
    throw "RCON did not return '$Pattern'. Last error: $lastError"
}

function Wait-LogPattern([string]$Path, [string]$Pattern, [int]$Seconds, [System.Diagnostics.Process]$Process) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Process.HasExited) {
            throw "Factorio exited while waiting for '$Pattern'."
        }
        if (Test-Path -LiteralPath $Path) {
            $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($text -match $Pattern) { return }
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Timed out waiting for '$Pattern' in $Path."
}

function Wait-ConnectedPlayer([int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $count = Invoke-Rcon '/silent-command rcon.print(#game.connected_players)'
            if ($count -match '(^|\D)1($|\D)') { return }
        } catch {
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'The isolated graphical client did not join the server.'
}

try {
    if (Get-Process factorio -ErrorAction SilentlyContinue) {
        throw 'Factorio is already running. The isolated E2E test will not interfere with it.'
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

    & (Join-Path $PSScriptRoot 'Test-Project.ps1') -FactorioExe $FactorioExe
    if ($LASTEXITCODE -ne 0) { throw 'Baseline project tests failed.' }

    $testRoot = Assert-UnderTestRoot $testRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    $serverData = Join-Path $testRoot 'server-data'
    $clientData = Join-Path $testRoot 'client-data'
    $logs = Join-Path $testRoot 'logs'
    New-Item -ItemType Directory -Path $serverData, $clientData, $logs -Force | Out-Null

    $factorioInstall = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $FactorioExe))))
    $readData = Join-Path $factorioInstall 'data'
    $mods = Join-Path $baseTestRoot 'mods'
    $map = Join-Path $baseTestRoot 'alina-test.zip'
    $serverConfig = Join-Path $testRoot 'server.ini'
    $clientConfig = Join-Path $testRoot 'client.ini'
    "[path]`r`nread-data=$readData`r`nwrite-data=$serverData`r`n" | Set-Content -LiteralPath $serverConfig -Encoding UTF8
    $clientConfigText = "[path]`r`nread-data=$readData`r`nwrite-data=$clientData`r`n`r`n[graphics]`r`ngraphics-quality=medium`r`nvideo-memory-usage=medium`r`ntexture-streaming=true`r`ntexture-compression-level=high-quality`r`nmax-texture-size=0`r`nmax-threads=8`r`nv-sync=false`r`nhigh-quality-animations=false`r`nhigh-quality-shadows=false`r`nshow-smoke=false`r`nshow-clouds=false`r`nshow-fog=false`r`nshow-space-dust=false`r`nshow-particles=false`r`nshow-animated-water=false`r`nshow-tree-distortion=false`r`nshow-game-simulations-in-background=false`r`n"
    $clientConfigText | Set-Content -LiteralPath $clientConfig -Encoding UTF8

    $serverSettings = Join-Path $testRoot 'server-settings.json'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tests\fixtures\server-settings.json') -Destination $serverSettings

    $script:bridgeConfig = Join-Path $testRoot 'bridge.json'
    $eventFile = Join-Path $serverData 'script-output\alina\events.jsonl'
    $cursorFile = Join-Path $testRoot 'cursor.json'
    @{
        ollama = @{
            baseUrl = 'http://127.0.0.1:11434'
            model = 'qwen3.5:4b'
            contextTokens = 8192
            keepAlive = '0'
            timeoutSeconds = 90
        }
        factorio = @{
            eventFile = $eventFile
            cursorFile = $cursorFile
            rconHost = '127.0.0.1'
            rconPort = $rconPort
            rconPassword = ''
            rconTimeoutSeconds = 5
            replayExistingEvents = $false
            pollMilliseconds = 100
        }
        safety = @{ maxMineAmount = 10 }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:bridgeConfig -Encoding UTF8

    $script:bridgeDll = Join-Path $projectRoot 'bridge\Alina.Bridge\bin\Release\net8.0\Alina.Bridge.dll'
    $env:ALINA_RCON_PASSWORD = $rconPassword

    $serverStdout = Join-Path $logs 'server.stdout.log'
    $serverArgs = '--config "{0}" --mod-directory "{1}" --start-server "{2}" --bind 127.0.0.1:{3} --server-settings "{4}" --rcon-bind 127.0.0.1:{5} --rcon-password "{6}" --no-log-rotation' -f $serverConfig, $mods, $map, $gamePort, $serverSettings, $rconPort, $rconPassword
    $server = Start-Process -FilePath $FactorioExe -ArgumentList $serverArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $serverStdout -RedirectStandardError (Join-Path $logs 'server.stderr.log')
    $processes.Add($server)
    Wait-LogPattern $serverStdout 'Starting RCON interface' 30 $server
    Wait-RconReply "/silent-command rcon.print('ready')" 'ready' 15 | Out-Null

    $clientArgs = '--config "{0}" --mod-directory "{1}" --mp-connect 127.0.0.1:{2} --fullscreen=false --window-size 1024x768 --disable-audio --no-log-rotation' -f $clientConfig, $mods, $gamePort
    $client = Start-Process -FilePath $FactorioExe -ArgumentList $clientArgs -WindowStyle Hidden -PassThru
    $processes.Add($client)
    Wait-ConnectedPlayer 60
    Wait-RconReply "/silent-command local p=game.connected_players[1]; local s=remote.call('alina_ai','status'); rcon.print(p.character and s.agent.present and 'ready' or 'waiting')" 'ready' 30 | Out-Null

    $bridge = Start-Process -FilePath 'dotnet' -ArgumentList ('"{0}" --config "{1}"' -f $script:bridgeDll, $script:bridgeConfig) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $logs 'bridge.stdout.log') -RedirectStandardError (Join-Path $logs 'bridge.stderr.log')
    $processes.Add($bridge)
    Start-Sleep -Seconds 1
    if ($bridge.HasExited) { throw 'Bridge exited before the chat command.' }

    # Build a controlled clear corridor only inside the disposable test map.
    # The 14-tile distance proves both outbound and return async paths.
    $prepare = "/silent-command local p=game.connected_players[1]; local s=p.surface; local bx=math.floor(p.position.x); local by=math.floor(p.position.y); local tiles={}; for x=-2,16 do for y=-4,4 do tiles[#tiles+1]={name='grass-1',position={bx+x,by+y}} end end; s.set_tiles(tiles,true,false,true,false); for _,name in pairs({'iron-ore','stone','coal'}) do for _,e in pairs(s.find_entities_filtered({position={bx,by},radius=64,name=name})) do if e.valid then e.destroy() end end end; for _,e in pairs(s.find_entities_filtered({area={{bx-2,by-4},{bx+17,by+5}},type={'tree','simple-entity','cliff','resource','wall'}})) do if e.valid then e.destroy() end end; p.teleport({bx+0.5,by+0.5}); local machine=s.create_entity({name='assembling-machine-1',position={bx+0.5,by+3.5},force=p.force}); if not machine then error('controlled machine creation failed') end; machine.set_recipe('iron-gear-wheel'); local stats=p.force.get_item_production_statistics(s); stats.on_flow('iron-plate',100); stats.on_flow('iron-plate',-200); local ore=s.create_entity({name='iron-ore',position={bx+14.5,by+0.5},amount=1000}); local stone=s.create_entity({name='stone',position={bx+14.5,by+3.5},amount=1000}); local coal=s.create_entity({name='coal',position={bx+14.5,by-3.5},amount=1000}); if not ore or not stone or not coal then error('controlled resource creation failed') end; if not remote.call('alina_ai','recall',p.index) then error('agent recall failed') end; local a=remote.call('alina_ai','status').agent; rcon.print(helpers.table_to_json({resource=ore.name,distance=math.sqrt((a.position.x-ore.position.x)^2+(a.position.y-ore.position.y)^2)}))"
    $prepared = Invoke-Rcon $prepare
    if ($prepared -notmatch 'iron-ore') { throw "Could not prepare an iron target: $prepared" }

    # Queue autonomy and the direct command in the same simulation tick. The
    # direct request must invalidate the autonomous request before either LLM
    # response can mutate the world (PLAYER INTENT > AI INTENT).
    $addressed = Invoke-Rcon "/silent-command local p=game.connected_players[1]; local autonomous=remote.call('alina_ai','autonomy_pulse',p.index); local m=[[$chatMessage]]; local parsed=remote.call('alina_ai','parse_address',m); local queued=remote.call('alina_ai','address',p.index,m); rcon.print(helpers.table_to_json({autonomous=autonomous,parsed=parsed,ok=queued.ok,result=queued.result}))"
    if ($addressed -notmatch '"ok":true' -or $addressed -notmatch '"result":"queued"') {
        throw "The command was not queued by the chat entry point: $addressed"
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $completed = $false
    $resourcePathReady = $false
    $deliveryPathReady = $false
    $factorySnapshotReady = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($bridge.HasExited) { throw 'Bridge exited during the task.' }
        if (Test-Path -LiteralPath $eventFile) {
            foreach ($line in Get-Content -LiteralPath $eventFile -Encoding UTF8) {
                if ($line -match '"event":"addressed_chat"') {
                    $chatEvent = $line | ConvertFrom-Json
                    $factory = $chatEvent.payload.snapshot.factory
                    if (($factory.machine_count -ge 1) -and
                        ($factory.active_recipes.name -contains 'iron-gear-wheel') -and
                        ($factory.item_flows.name -contains 'iron-plate')) {
                        $factorySnapshotReady = $true
                    }
                }
                if ($line -match '"event":"navigation_ready"') {
                    $navigationEvent = $line | ConvertFrom-Json
                    if ($navigationEvent.payload.purpose -eq 'resource') { $resourcePathReady = $true }
                    if ($navigationEvent.payload.purpose -eq 'delivery') { $deliveryPathReady = $true }
                }
                if ($line -notmatch '"event":"task_completed"') { continue }
                $event = $line | ConvertFrom-Json
                if ($event.payload.resource -eq 'iron-ore' -and $event.payload.amount -ge 1 -and $event.payload.delivered -ge 1) {
                    $completed = $true
                    break
                }
            }
        }
        if ($completed) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $completed) {
        $status = Invoke-Rcon "/silent-command rcon.print(helpers.table_to_json(remote.call('alina_ai','status')))"
        throw "Mining task did not complete within $TimeoutSeconds seconds. Status: $status"
    }
    if (-not $resourcePathReady -or -not $deliveryPathReady) {
        throw "Task completed without proving both async paths. resource=$resourcePathReady delivery=$deliveryPathReady prepared=$prepared"
    }
    if (-not $factorySnapshotReady) {
        throw 'Task completed without a grounded factory recipe and production-flow snapshot.'
    }
    $priorityStatus = Invoke-Rcon "/silent-command rcon.print(helpers.table_to_json(remote.call('alina_ai','status').metrics))"
    if ($priorityStatus -notmatch '"autonomy_superseded":1') {
        throw "Direct player intent did not supersede the pending autonomous request: $priorityStatus"
    }

    $shortageAddressed = Invoke-Rcon "/silent-command local p=game.connected_players[1]; local m=[[$shortageMessage]]; local queued=remote.call('alina_ai','address',p.index,m); rcon.print(helpers.table_to_json({ok=queued.ok,result=queued.result}))"
    if ($shortageAddressed -notmatch '"ok":true' -or $shortageAddressed -notmatch '"result":"queued"') {
        throw "The shortage command was not queued: $shortageAddressed"
    }

    $diagnosisDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $diagnosed = $false
    $diagnosisReason = $null
    $materialsReady = $false
    $solutionVerified = $false
    $verifiedProduction = 0
    while ([DateTime]::UtcNow -lt $diagnosisDeadline) {
        if ($bridge.HasExited) { throw 'Bridge exited during shortage diagnosis.' }
        foreach ($line in Get-Content -LiteralPath $eventFile -Encoding UTF8 -ErrorAction SilentlyContinue) {
            if ($line -notmatch '"event":"shortage_diagnosed"') { continue }
            $diagnosisEvent = $line | ConvertFrom-Json
            if ($diagnosisEvent.payload.target_item -eq 'iron-plate') {
                $diagnosed = $true
                $diagnosisReason = $diagnosisEvent.payload.reason
                break
            }
        }
        foreach ($line in Get-Content -LiteralPath $eventFile -Encoding UTF8 -ErrorAction SilentlyContinue) {
            if ($line -notmatch '"event":"shortage_materials_ready"') { continue }
            $materialsEvent = $line | ConvertFrom-Json
            if (($materialsEvent.payload.target_item -eq 'iron-plate') -and
                ($materialsEvent.payload.placement_item -eq 'stone-furnace')) {
                $materialsReady = $true
                break
            }
        }
        foreach ($line in Get-Content -LiteralPath $eventFile -Encoding UTF8 -ErrorAction SilentlyContinue) {
            if ($line -notmatch '"event":"shortage_solution_verified"') { continue }
            $verifiedEvent = $line | ConvertFrom-Json
            if (($verifiedEvent.payload.target_item -eq 'iron-plate') -and
                ($verifiedEvent.payload.entity -eq 'stone-furnace') -and
                ($verifiedEvent.payload.produced -ge 1)) {
                $solutionVerified = $true
                $verifiedProduction = $verifiedEvent.payload.produced
                break
            }
        }
        if ($diagnosed -and $materialsReady -and $solutionVerified) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $diagnosed) {
        $status = Invoke-Rcon "/silent-command rcon.print(helpers.table_to_json(remote.call('alina_ai','status')))"
        throw "Shortage diagnosis did not complete within $TimeoutSeconds seconds. Status: $status"
    }
    if ($diagnosisReason -ne 'no_local_producer') {
        throw "Unexpected deterministic shortage diagnosis: $diagnosisReason"
    }
    if (-not $materialsReady) {
        throw 'Shortage diagnosis did not autonomously acquire and craft a stone-furnace.'
    }
    if (-not $solutionVerified) {
        throw 'The autonomous producer was not built, fueled, supplied and verified.'
    }
    $builtCount = Invoke-Rcon "/silent-command local p=game.connected_players[1]; rcon.print(p.surface.count_entities_filtered({position=p.position,radius=32,name='stone-furnace',force=p.force}))"
    if ([int]($builtCount -replace '\D','') -lt 1) {
        throw "The verified stone-furnace is missing from the test surface: $builtCount"
    }

    # Prove that the same safe repair can be selected without a player command.
    # Clearing only disposable-map statistics removes the earlier iron deficit,
    # leaving one unambiguous copper-plate bottleneck for the autonomous planner.
    $prepareAutonomy = "/silent-command local p=game.connected_players[1]; local s=p.surface; local bx=math.floor(p.position.x); local by=math.floor(p.position.y); local stats=p.force.get_item_production_statistics(s); stats.clear(); stats.on_flow('copper-plate',100); stats.on_flow('copper-plate',-200); for _,e in pairs(s.find_entities_filtered({position={bx,by},radius=64,name='copper-ore'})) do if e.valid then e.destroy() end end; local copper=s.create_entity({name='copper-ore',position={bx+14.5,by+1.5},amount=1000}); if not copper then error('controlled copper creation failed') end; rcon.print(helpers.table_to_json({resource=copper.name,target='copper-plate'}))"
    $autonomyPrepared = Invoke-Rcon $prepareAutonomy
    if ($autonomyPrepared -notmatch 'copper-plate') { throw "Could not prepare autonomous shortage: $autonomyPrepared" }

    $pulse = Invoke-Rcon "/silent-command local p=game.connected_players[1]; rcon.print(helpers.table_to_json(remote.call('alina_ai','autonomy_pulse',p.index)))"
    if ($pulse -notmatch '"ok":true') { throw "Autonomous pulse was not queued: $pulse" }

    $autonomyDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $autonomyRequested = $false
    $autonomyVerified = $false
    while ([DateTime]::UtcNow -lt $autonomyDeadline) {
        if ($bridge.HasExited) { throw 'Bridge exited during autonomous planning.' }
        foreach ($line in Get-Content -LiteralPath $eventFile -Encoding UTF8 -ErrorAction SilentlyContinue) {
            if ($line -match '"event":"autonomy_requested"') {
                $requestEvent = $line | ConvertFrom-Json
                if ($requestEvent.payload.source -eq 'autonomous') { $autonomyRequested = $true }
            }
            if ($line -match '"event":"shortage_solution_verified"') {
                $autonomyEvent = $line | ConvertFrom-Json
                if (($autonomyEvent.payload.target_item -eq 'copper-plate') -and
                    ($autonomyEvent.payload.entity -eq 'stone-furnace') -and
                    ($autonomyEvent.payload.produced -ge 1)) {
                    $autonomyVerified = $true
                }
            }
        }
        if ($autonomyRequested -and $autonomyVerified) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $autonomyRequested) { throw 'No autonomous factory assessment event was emitted.' }
    if (-not $autonomyVerified) {
        $status = Invoke-Rcon "/silent-command rcon.print(helpers.table_to_json(remote.call('alina_ai','status')))"
        throw "Autonomous copper producer was not verified. Status: $status"
    }
    $autonomyStatus = Invoke-Rcon "/silent-command rcon.print(helpers.table_to_json(remote.call('alina_ai','status').metrics))"
    if ($autonomyStatus -notmatch '"autonomy_actions":1') {
        throw "Autonomous action metric was not recorded: $autonomyStatus"
    }

    # Exhaust the owned copper furnace and prove that a new diagnosis refills
    # the existing producer instead of building a duplicate.
    $emptyCopper = Invoke-Rcon "/silent-command local p=game.connected_players[1]; local found=nil; for _,e in pairs(p.surface.find_entities_filtered({position=p.position,radius=32,name='stone-furnace',force=p.force})) do local r=e.get_recipe(); if r and r.name=='copper-plate' then found=e; break end end; if not found then error('owned copper furnace missing') end; found.get_inventory(defines.inventory.crafter_input).clear(); rcon.print(found.name)"
    if ($emptyCopper -notmatch 'stone-furnace') { throw "Could not empty copper furnace: $emptyCopper" }
    Wait-RconReply "/silent-command local p=game.connected_players[1]; for _,e in pairs(p.surface.find_entities_filtered({position=p.position,radius=32,name='stone-furnace',force=p.force})) do local r=e.get_recipe(); if r and r.name=='copper-plate' then rcon.print(e.status==defines.entity_status.no_ingredients and 'empty' or 'waiting'); return end end; rcon.print('missing')" 'empty' 15 | Out-Null

    $maintenanceAddressed = Invoke-Rcon "/silent-command local p=game.connected_players[1]; local m=[[$maintenanceMessage]]; local queued=remote.call('alina_ai','address',p.index,m); rcon.print(helpers.table_to_json({ok=queued.ok,result=queued.result}))"
    if ($maintenanceAddressed -notmatch '"ok":true' -or $maintenanceAddressed -notmatch '"result":"queued"') {
        throw "The producer-maintenance command was not queued: $maintenanceAddressed"
    }

    $maintenanceDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $maintenanceTaskId = $null
    $maintenanceVerified = $false
    while ([DateTime]::UtcNow -lt $maintenanceDeadline) {
        if ($bridge.HasExited) { throw 'Bridge exited during producer maintenance.' }
        foreach ($line in Get-Content -LiteralPath $eventFile -Encoding UTF8 -ErrorAction SilentlyContinue) {
            if ($line -match '"event":"shortage_refill_planned"') {
                $refillEvent = $line | ConvertFrom-Json
                if (($refillEvent.payload.target_item -eq 'copper-plate') -and $refillEvent.payload.owned) {
                    $maintenanceTaskId = $refillEvent.payload.task_id
                }
            }
            if ($maintenanceTaskId -and $line -match '"event":"shortage_solution_verified"') {
                $maintenanceEvent = $line | ConvertFrom-Json
                if (($maintenanceEvent.payload.task_id -eq $maintenanceTaskId) -and
                    ($maintenanceEvent.payload.target_item -eq 'copper-plate') -and
                    ($maintenanceEvent.payload.produced -ge 1)) {
                    $maintenanceVerified = $true
                }
            }
        }
        if ($maintenanceTaskId -and $maintenanceVerified) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $maintenanceTaskId) { throw 'Existing owned producer was not selected for refill.' }
    if (-not $maintenanceVerified) { throw 'Refilled copper producer did not resume verified output.' }
    $finalFurnaceCount = Invoke-Rcon "/silent-command local p=game.connected_players[1]; rcon.print(p.surface.count_entities_filtered({position=p.position,radius=32,name='stone-furnace',force=p.force}))"
    if ([int]($finalFurnaceCount -replace '\D','') -ne 2) {
        throw "Producer maintenance built an unexpected duplicate: $finalFurnaceCount furnaces"
    }

    $bridgeLog = Get-Content -LiteralPath (Join-Path $logs 'bridge.stdout.log') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Output 'VERTICAL MVP + AUTONOMOUS FACTORY REPAIR + PRODUCER MAINTENANCE E2E OK'
    Write-Output "Commands: $chatMessage | $shortageMessage | $maintenanceMessage"
    Write-Output ($bridgeLog.Trim())
    Write-Output "Artifacts: $testRoot"
} finally {
    for ($index = $processes.Count - 1; $index -ge 0; $index--) {
        $process = $processes[$index]
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $process.WaitForExit(5000) | Out-Null
        }
    }
    if ($null -eq $previousPassword) {
        Remove-Item Env:\ALINA_RCON_PASSWORD -ErrorAction SilentlyContinue
    } else {
        $env:ALINA_RCON_PASSWORD = $previousPassword
    }
}
