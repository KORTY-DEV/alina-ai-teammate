[CmdletBinding()]
param(
    [string]$SaveCopy,
    [string]$FactorioExe,
    [int]$TimeoutSeconds = 180,
    [switch]$ExercisePowerRepair,
    [switch]$ExerciseFactoryCommand,
    [switch]$AllowLegacyMultiplayerHarness
)

$ErrorActionPreference = 'Stop'
if (-not $AllowLegacyMultiplayerHarness) {
    throw 'This legacy server/client harness is disabled by default. Use Test-PlayableSaveCopyLocal.ps1 for the normal single-process copied-save test.'
}
$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$safeRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot '.test-output\real-save-playable'))
$currentRoot = Join-Path $safeRoot 'current'
if (-not $SaveCopy) { $SaveCopy = Join-Path $currentRoot 'playable-copy.zip' }
$SaveCopy = [System.IO.Path]::GetFullPath($SaveCopy)
if (-not $SaveCopy.StartsWith($safeRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to load a save outside the isolated playable-test root: $SaveCopy"
}
if (-not (Test-Path -LiteralPath $SaveCopy)) { throw "Save copy not found: $SaveCopy" }
if ($ExercisePowerRepair -and $ExerciseFactoryCommand) { throw 'Choose only one copied-save exercise.' }
if (Get-Process factorio -ErrorAction SilentlyContinue) {
    throw 'Factorio is already running; refusing to mix the isolated inspection with another game process.'
}

if (-not $FactorioExe) {
    $FactorioExe = @(
        'D:\Games\Factorio Space Age v2.1.12b\Factorio Space Age v2.1.12b\bin\x64\factorio.exe',
        'C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe'
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $FactorioExe) { throw 'Factorio executable not found.' }

$runRoot = Join-Path $safeRoot ('inspect-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$serverData = Join-Path $runRoot 'server-data'
$clientData = Join-Path $runRoot 'client-data'
$logs = Join-Path $runRoot 'logs'
$mods = Join-Path $currentRoot 'mods'
New-Item -ItemType Directory -Path $serverData, $clientData, $logs -Force | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $mods 'alina-ai-teammate_0.1.0\info.json'))) {
    throw "Isolated mod set is missing Alina: $mods"
}

$factorioInstall = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $FactorioExe))))
$readData = Join-Path $factorioInstall 'data'
$serverConfig = Join-Path $runRoot 'server.ini'
"[path]`r`nread-data=$readData`r`nwrite-data=$serverData`r`n" | Set-Content -LiteralPath $serverConfig -Encoding UTF8
$clientConfig = Join-Path $runRoot 'client.ini'
$clientConfigText = "[path]`r`nread-data=$readData`r`nwrite-data=$clientData`r`n`r`n[graphics]`r`ngraphics-quality=medium`r`nvideo-memory-usage=medium`r`ntexture-streaming=true`r`ntexture-compression-level=high-quality`r`nmax-texture-size=0`r`nmax-threads=8`r`nv-sync=false`r`nhigh-quality-animations=false`r`nhigh-quality-shadows=false`r`nshow-smoke=false`r`nshow-clouds=false`r`nshow-fog=false`r`nshow-space-dust=false`r`nshow-particles=false`r`nshow-animated-water=false`r`nshow-tree-distortion=false`r`nshow-game-simulations-in-background=false`r`n"
$clientConfigText | Set-Content -LiteralPath $clientConfig -Encoding UTF8
$serverSettings = Join-Path $runRoot 'server-settings.json'
Copy-Item -LiteralPath (Join-Path $projectRoot 'tests\fixtures\server-settings.json') -Destination $serverSettings

$rconPort = 34318
$gamePort = 34317
$rconPassword = 'alina-isolated-real-save'
$bridgeConfig = Join-Path $runRoot 'bridge.json'
@{
    ollama = @{ baseUrl = 'http://127.0.0.1:11434'; model = 'qwen3.5:4b'; contextTokens = 8192; keepAlive = '0'; timeoutSeconds = 90 }
    factorio = @{
        eventFile = (Join-Path $serverData 'script-output\alina\events.jsonl')
        cursorFile = (Join-Path $runRoot 'cursor.json')
        rconHost = '127.0.0.1'; rconPort = $rconPort; rconPassword = ''
        rconTimeoutSeconds = 10; replayExistingEvents = $false; pollMilliseconds = 100
    }
    safety = @{ maxMineAmount = 10 }
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $bridgeConfig -Encoding UTF8

$bridgeDll = Join-Path $projectRoot 'bridge\Alina.Bridge\bin\Release\net8.0\Alina.Bridge.dll'
$previousPassword = $env:ALINA_RCON_PASSWORD
$env:ALINA_RCON_PASSWORD = $rconPassword
$server = $null
$client = $null
$bridge = $null

function Invoke-Rcon([string]$Command) {
    $output = & dotnet $bridgeDll --config $bridgeConfig --rcon-command $Command 2>&1
    if ($LASTEXITCODE -ne 0) { throw "RCON failed: $($output -join [Environment]::NewLine)" }
    return ($output -join [Environment]::NewLine).Trim()
}

try {
    $stdout = Join-Path $logs 'server.stdout.log'
    $stderr = Join-Path $logs 'server.stderr.log'
    $arguments = '--config "{0}" --mod-directory "{1}" --start-server "{2}" --bind 127.0.0.1:{3} --server-settings "{4}" --rcon-bind 127.0.0.1:{5} --rcon-password "{6}" --no-log-rotation' -f $serverConfig, $mods, $SaveCopy, $gamePort, $serverSettings, $rconPort, $rconPassword
    $server = Start-Process -FilePath $FactorioExe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($server.HasExited) { throw "Factorio exited while loading the save copy. See $stdout" }
        if ((Test-Path -LiteralPath $stdout) -and (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) -match 'Starting RCON interface') { break }
        Start-Sleep -Milliseconds 500
    }
    if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out loading the save copy. See $stdout" }

    $playersJson = Invoke-Rcon "/silent-command local rows={}; for _,p in pairs(game.players) do rows[#rows+1]={index=p.index,name=p.name,connected=p.connected,has_character=p.character~=nil,surface=p.surface.name,position={x=p.position.x,y=p.position.y},last_online=p.last_online} end; rcon.print(helpers.table_to_json(rows))"
    $players = $playersJson | ConvertFrom-Json
    $owner = $players | Where-Object has_character | Sort-Object last_online -Descending | Select-Object -First 1
    if (-not $owner) {
        $clientArguments = '--config "{0}" --mod-directory "{1}" --mp-connect 127.0.0.1:{2} --fullscreen=false --window-size 1024x768 --disable-audio --no-log-rotation' -f $clientConfig, $mods, $gamePort
        $client = Start-Process -FilePath $FactorioExe -ArgumentList $clientArguments -WindowStyle Hidden -PassThru
        $clientDeadline = [DateTime]::UtcNow.AddSeconds(90)
        while ([DateTime]::UtcNow -lt $clientDeadline) {
            if ($client.HasExited) { throw "Graphical client exited while joining the copied save. See $clientData\factorio-current.log" }
            try {
                $ready = Invoke-Rcon "/silent-command local p=game.connected_players[1]; rcon.print(p and 'player-ready' or 'waiting')"
                if ($ready -match 'player-ready') { break }
            } catch {
            }
            Start-Sleep -Milliseconds 500
        }
        if ([DateTime]::UtcNow -ge $clientDeadline) { throw 'Graphical client did not restore a player character.' }
        $playersJson = Invoke-Rcon "/silent-command local rows={}; for _,p in pairs(game.players) do rows[#rows+1]={index=p.index,name=p.name,connected=p.connected,has_character=p.character~=nil,surface=p.surface.name,position={x=p.position.x,y=p.position.y},last_online=p.last_online} end; rcon.print(helpers.table_to_json(rows))"
        $players = $playersJson | ConvertFrom-Json
        $owner = $players | Where-Object connected | Select-Object -First 1
    }
    if (-not $owner) { throw "No player character could be restored in the copied save: $playersJson" }

    $editorResultJson = Invoke-Rcon "/silent-command rcon.print(helpers.table_to_json(remote.call('alina_ai','disable_editor',$($owner.index))))"
    $editorResult = $editorResultJson | ConvertFrom-Json
    if (-not $editorResult.ok -and $editorResult.result -ne 'not_editor') {
        throw "Could not switch the copied save out of editor controller: $editorResultJson"
    }
    $agentReady = Invoke-Rcon "/silent-command rcon.print(remote.call('alina_ai','recall',$($owner.index)) and 'agent-ready' or 'agent-failed')"
    if ($agentReady -notmatch 'agent-ready') { throw "Alina could not spawn beside the existing player: $agentReady" }
    $agentStatusJson = Invoke-Rcon "/silent-command rcon.print(helpers.table_to_json(remote.call('alina_ai','status').agent))"
    $agentStatus = $agentStatusJson | ConvertFrom-Json
    if (-not $agentStatus.map_visible) { throw 'Alina was not exposed as a moving map marker.' }
    $snapshotJson = Invoke-Rcon "/silent-command rcon.print(helpers.table_to_json(remote.call('alina_ai','snapshot',$($owner.index))))"
    if ($snapshotJson -notmatch '^\s*\{') { throw "Snapshot command failed: $snapshotJson" }
    $snapshot = $snapshotJson | ConvertFrom-Json
    if (-not $snapshot.ok -or -not $snapshot.snapshot.alina.present) { throw 'Snapshot did not contain the Alina character.' }

    $artifact = Join-Path $runRoot 'existing-base-snapshot.json'
    $snapshot | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $artifact -Encoding UTF8
    $inventoryJson = Invoke-Rcon "/silent-command local p=game.get_player($($owner.index)); local rows={}; for _,e in pairs(p.surface.find_entities_filtered({position=p.position,radius=192,type={'container','logistic-container','linked-container','assembling-machine','furnace'},force=p.force})) do local inv=nil; if e.type=='container' or e.type=='logistic-container' or e.type=='linked-container' then inv=e.get_inventory(defines.inventory.chest) else inv=e.get_inventory(defines.inventory.crafter_output) end; if inv and not inv.is_empty() then rows[#rows+1]={name=e.name,position=e.position,items=inv.get_contents()} end end; local energy={}; for _,e in pairs(p.surface.find_entities_filtered({position=p.position,radius=512,type={'generator','burner-generator','solar-panel','boiler','reactor','fusion-generator','fusion-reactor','electric-energy-interface'},force=p.force})) do local fuel=nil; if e.burner and e.burner.inventory then fuel=e.burner.inventory.get_contents() end; energy[#energy+1]={name=e.name,type=e.type,status=e.status,position=e.position,energy=e.energy,fuel=fuel} end; local poles={}; for _,e in pairs(p.surface.find_entities_filtered({position=p.position,radius=512,type='electric-pole',force=p.force})) do poles[#poles+1]={name=e.name,position=e.position,network=e.electric_network_id} end; rcon.print(helpers.table_to_json({player=p.get_main_inventory().get_contents(),sources=rows,energy=energy,poles=poles}))"
    $inventoryArtifact = Join-Path $runRoot 'existing-base-inventories.json'
    ($inventoryJson | ConvertFrom-Json) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $inventoryArtifact -Encoding UTF8
    $powerResult = 'not_requested'
    if ($ExercisePowerRepair) {
        $powerIssue = @($snapshot.snapshot.factory.issues | Where-Object status -eq 'no_power' |
            Sort-Object count -Descending | Select-Object -First 1)[0]
        if (-not $powerIssue) { throw 'No grounded no_power issue exists in the copied save.' }
        $pulseJson = Invoke-Rcon "/silent-command rcon.print(helpers.table_to_json(remote.call('alina_ai','autonomy_pulse',$($owner.index))))"
        $pulse = $pulseJson | ConvertFrom-Json
        if (-not $pulse.ok) { throw "Could not queue autonomous repair request: $pulseJson" }
        $plan = "{version=1,request_id='$($pulse.result)',intent='repair_power',reply='Power repair',requires_confirmation=false,actions={{id='power-real-1',type='repair_power',args={entity='$($powerIssue.name)'}}}}"
        $submitted = Invoke-Rcon "/silent-command rcon.print(helpers.table_to_json(remote.call('alina_ai','submit_plan',$plan)))"
        if ($submitted -notmatch '"ok":true') { throw "Power plan was rejected: $submitted" }
        $eventFile = Join-Path $serverData 'script-output\alina\events.jsonl'
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($server.HasExited -or ($client -and $client.HasExited)) { throw 'Factorio exited during copied-save power repair.' }
            $events = Get-Content -LiteralPath $eventFile -Encoding UTF8 -ErrorAction SilentlyContinue
            $verified = $events | Where-Object { $_ -match '"event":"power_repair_verified"' } | Select-Object -Last 1
            $failed = $events | Where-Object { $_ -match '"event":"task_finished"' -and $_ -match '"status":"failed"' } | Select-Object -Last 1
            if ($verified) {
                $powerResult = ($verified | ConvertFrom-Json).payload
                break
            }
            if ($failed) {
                $unavailable = $events | Where-Object { $_ -match '"event":"power_repair_unavailable"' } | Select-Object -Last 1
                throw "Power repair failed: $failed Diagnostics: $unavailable"
            }
            Start-Sleep -Milliseconds 500
        }
        if ($powerResult -is [string]) {
            $status = Invoke-Rcon "/silent-command rcon.print(helpers.table_to_json(remote.call('alina_ai','status')))"
            throw "Power repair timed out. Status: $status"
        }
    }
    $factoryCommandResult = 'not_requested'
    if ($ExerciseFactoryCommand) {
        Invoke-Rcon "/silent-command game.speed=4" | Out-Null
        $eventFile = Join-Path $serverData 'script-output\alina\events.jsonl'
        $before = @(Get-Content -LiteralPath $eventFile -Encoding UTF8 -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $null -ne $_ })
        $baselineEventId = @($before | Measure-Object -Property event_id -Maximum).Maximum
        if ($null -eq $baselineEventId) { $baselineEventId = 0 }
        $factoryMessage = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0JDQu9GPLCDQv9GA0L7QtNC+0LvQttCw0Lkg0YDQsNC30LLQuNCy0LDRgtGMINCx0LDQt9GD'))
        $queued = Invoke-Rcon "/silent-command local p=game.get_player($($owner.index)); local q=remote.call('alina_ai','address',p.index,[=[$factoryMessage]=]); rcon.print(helpers.table_to_json(q))"
        if ($queued -notmatch '"ok":true' -or $queued -notmatch '"result":"local_control"') {
            throw "Factory command was not accepted by local control: $queued"
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $factoryEnabled = $false
        $latestFailures = @()
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($server.HasExited -or ($client -and $client.HasExited)) {
                throw 'Factorio exited during copied-save factory development.'
            }
            $events = @(Get-Content -LiteralPath $eventFile -Encoding UTF8 -ErrorAction SilentlyContinue |
                ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } |
                Where-Object { $null -ne $_ -and $_.event_id -gt $baselineEventId })
            if ($events | Where-Object event -eq 'factory_development_enabled') { $factoryEnabled = $true }
            $verified = $events | Where-Object {
                $_.event -eq 'task_finished' -and $_.payload.status -eq 'completed' -and
                $_.payload.task_type -in @('expand_line', 'repair_power')
            } | Select-Object -Last 1
            if ($factoryEnabled -and $verified) {
                $factoryCommandResult = "verified:$($verified.payload.task_type)"
                break
            }
            $latestFailures = @($events | Where-Object {
                $_.event -eq 'task_finished' -and $_.payload.status -eq 'failed'
            } | Select-Object -Last 3)
            Start-Sleep -Milliseconds 500
        }
        if ($factoryCommandResult -notlike 'verified:*') {
            $status = Invoke-Rcon "/silent-command rcon.print(helpers.table_to_json(remote.call('alina_ai','status')))"
            $failures = $latestFailures | ConvertTo-Json -Depth 6 -Compress
            throw "Factory command timed out without a completed useful task. Status: $status Failures: $failures"
        }
    }
    [pscustomobject]@{
        Result = 'PLAYABLE SAVE COPY INSPECTION OK'
        SourceCopy = $SaveCopy
        Player = $owner.name
        ControllerResult = $editorResult.result
        Surface = $snapshot.snapshot.surface
        Position = "$($snapshot.snapshot.player_position.x),$($snapshot.snapshot.player_position.y)"
        Machines = $snapshot.snapshot.factory.machine_count
        Infrastructure = $snapshot.snapshot.factory.infrastructure_count
        StorageGroups = @($snapshot.snapshot.factory.storage).Count
        ResearchedTechnologies = $snapshot.snapshot.technology.researched_count
        PowerRepair = if ($powerResult -is [string]) { $powerResult } else { "$($powerResult.restored) restored, $($powerResult.remaining) remaining" }
        FactoryCommand = $factoryCommandResult
        MapMarker = $agentStatus.map_visible
        Snapshot = $artifact
        Inventories = $inventoryArtifact
        RunRoot = $runRoot
    } | Format-List
} finally {
    if ($bridge -and -not $bridge.HasExited) {
        Stop-Process -Id $bridge.Id -Force -ErrorAction SilentlyContinue
        $bridge.WaitForExit(5000) | Out-Null
    }
    if ($client -and -not $client.HasExited) {
        Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
        $client.WaitForExit(5000) | Out-Null
    }
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
        $server.WaitForExit(5000) | Out-Null
    }
    if ($null -eq $previousPassword) { Remove-Item Env:\ALINA_RCON_PASSWORD -ErrorAction SilentlyContinue }
    else { $env:ALINA_RCON_PASSWORD = $previousPassword }
}
