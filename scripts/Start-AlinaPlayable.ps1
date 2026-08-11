[CmdletBinding()]
param(
    [string]$FactorioExe,
    [string]$SourceSave,
    [int]$BridgePort = 34198,
    [int]$FactorioUdpPort = 34199,
    [string]$LocalModel = 'qwen3.5:4b',
    [switch]$ResetPlayableCopy,
    [switch]$NewGame
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$factorioUser = Join-Path $env:APPDATA 'Factorio'
$modsRoot = Join-Path $factorioUser 'mods'
$savesRoot = Join-Path $factorioUser 'saves'
$runtime = Join-Path $projectRoot '.alina-runtime'
$logs = Join-Path $runtime 'logs'
$playableSave = Join-Path $savesRoot 'Alina-Playable.zip'
$sourceMod = Join-Path $projectRoot 'factorio-mod\alina-ai-teammate_0.1.0'
$targetMod = Join-Path $modsRoot 'alina-ai-teammate_0.1.0'

if (Get-Process factorio -ErrorAction SilentlyContinue) {
    throw 'Factorio уже запущена. Закрой её перед запуском Alina Playable.'
}
if ($BridgePort -eq $FactorioUdpPort) { throw 'UDP-порты bridge и Factorio должны отличаться.' }

if (-not $FactorioExe) {
    $FactorioExe = @(
        'D:\Games\Factorio Space Age v2.1.12b\Factorio Space Age v2.1.12b\bin\x64\factorio.exe',
        (Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\Factorio\bin\x64\factorio.exe'),
        (Join-Path $env:ProgramFiles 'Factorio\bin\x64\factorio.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
if (-not $FactorioExe) {
    throw 'Factorio executable не найден. Для нестандартной установки запусти scripts\Start-AlinaPlayable.ps1 с параметром -FactorioExe "полный-путь-к-factorio.exe".'
}
if (-not (Test-Path -LiteralPath $sourceMod)) { throw "Исходник мода Алины не найден: $sourceMod" }
if (-not (Test-Path -LiteralPath $modsRoot)) { throw "Папка модов Factorio не найдена: $modsRoot" }
if (-not (Test-Path -LiteralPath $savesRoot)) { New-Item -ItemType Directory -Path $savesRoot -Force | Out-Null }
New-Item -ItemType Directory -Path $runtime, $logs -Force | Out-Null

# Полный локальный режим использует .NET bridge и локальную модель только для
# ограниченных высокоуровневых запросов. Обычная автономия остаётся в Factorio.
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'Не найден .NET 8 SDK. Установи его командой: winget install Microsoft.DotNet.SDK.8'
}
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    throw 'Не найден Ollama. Установи его командой: winget install Ollama.Ollama — затем снова запусти Алину.'
}

Write-Host "Проверяю локальную модель $LocalModel..." -ForegroundColor Cyan
$ollamaList = & ollama list 2>&1
if ($LASTEXITCODE -ne 0) {
    throw 'Ollama установлен, но локальный сервис не отвечает. Запусти Ollama и повтори запуск.'
}
if (($ollamaList -join "`n") -notmatch [regex]::Escape($LocalModel)) {
    Write-Host "Первый запуск: загружаю модель $LocalModel. Это несколько гигабайт и выполняется один раз." -ForegroundColor Yellow
    & ollama pull $LocalModel
    if ($LASTEXITCODE -ne 0) { throw "Не удалось загрузить модель $LocalModel через Ollama." }
}

# Синхронизируем только наш development-мод. Все сторонние моды остаются нетронутыми.
$existingAlina = Get-ChildItem -LiteralPath $modsRoot -Force | Where-Object {
    $_.Name -like 'alina-ai-teammate*' -and $_.FullName -ne $targetMod
}
if ((Test-Path -LiteralPath $targetMod) -or $existingAlina.Count -gt 0) {
    $backupRoot = Join-Path $runtime ('mod-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    if (Test-Path -LiteralPath $targetMod) { Copy-Item -LiteralPath $targetMod -Destination $backupRoot -Recurse }
    foreach ($item in $existingAlina) { Copy-Item -LiteralPath $item.FullName -Destination $backupRoot -Recurse }
}
Get-ChildItem -LiteralPath $modsRoot -Force | Where-Object { $_.Name -like 'alina-ai-teammate*' } |
    Remove-Item -Recurse -Force
Copy-Item -LiteralPath $sourceMod -Destination $targetMod -Recurse

# Включаем только Alina в существующем mod-list.json, не меняя состояние других модов.
$modListPath = Join-Path $modsRoot 'mod-list.json'
if (Test-Path -LiteralPath $modListPath) {
    $modList = Get-Content -LiteralPath $modListPath -Raw | ConvertFrom-Json
    $entry = @($modList.mods) | Where-Object { $_.name -eq 'alina-ai-teammate' } | Select-Object -First 1
    $changed = $false
    if ($null -eq $entry) {
        $modList.mods = @($modList.mods) + [pscustomobject]@{ name = 'alina-ai-teammate'; enabled = $true }
        $changed = $true
    } elseif (-not $entry.enabled) {
        $entry.enabled = $true
        $changed = $true
    }
    if ($changed) {
        Copy-Item -LiteralPath $modListPath -Destination (Join-Path $runtime ('mod-list.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'))
        [System.IO.File]::WriteAllText(
            $modListPath,
            ($modList | ConvertTo-Json -Depth 20),
            [Text.UTF8Encoding]::new($false))
    }
}

if (-not $NewGame) {
    # Existing-save mode never works on the selected original save directly.
    # Первый запуск создаёт отдельную постоянную игровую копию; дальше продолжаем её.
    if ($ResetPlayableCopy -and (Test-Path -LiteralPath $playableSave)) {
        $saveBackup = Join-Path $runtime ('save-backups\Alina-Playable-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
        New-Item -ItemType Directory -Path (Split-Path -Parent $saveBackup) -Force | Out-Null
        Copy-Item -LiteralPath $playableSave -Destination $saveBackup
        Remove-Item -LiteralPath $playableSave -Force
    }

    if (-not (Test-Path -LiteralPath $playableSave)) {
        $legacyPlayable = Join-Path $runtime 'server-data\saves\Alina-Playable.zip'
        if (-not $SourceSave) {
            $candidates = @(Get-ChildItem -LiteralPath $savesRoot -Filter '*.zip' |
                Where-Object { $_.Name -notlike 'Alina-Playable*' })
            if (Test-Path -LiteralPath $legacyPlayable) { $candidates += Get-Item -LiteralPath $legacyPlayable }
            $SourceSave = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $SourceSave -or -not (Test-Path -LiteralPath $SourceSave)) {
            throw 'Не найден сейв для безопасной копии. Если хочешь начать с нуля, используй START_ALINA_NEW_GAME.cmd.'
        }
        Copy-Item -LiteralPath $SourceSave -Destination $playableSave
        [System.IO.File]::WriteAllText(
            (Join-Path $runtime 'playable-source.txt'),
            $SourceSave,
            [Text.UTF8Encoding]::new($false))
        Write-Host "Создана безопасная игровая копия: $playableSave" -ForegroundColor Green
        Write-Host "Исходный сейв не изменяется: $SourceSave"
    } else {
        Write-Host "Продолжаю существующий сейв Алины: $playableSave" -ForegroundColor Green
    }
} else {
    Write-Host 'Режим НОВОЙ ИГРЫ: Factorio откроется в главном меню. Создай обычный новый мир — Алина уже будет включена.' -ForegroundColor Green
}

$bridgeConfig = Join-Path $runtime 'bridge-udp.json'
$bridgeSettings = @{
    ollama = @{
        baseUrl = 'http://127.0.0.1:11434'
        model = $LocalModel
        contextTokens = 8192
        keepAlive = '0'
        timeoutSeconds = 90
    }
    factorio = @{
        transport = 'udp'
        udpBridgePort = $BridgePort
        udpFactorioPort = $FactorioUdpPort
        udpHeartbeatMilliseconds = 1000
        eventFile = (Join-Path $factorioUser 'script-output\alina\events.jsonl')
        cursorFile = (Join-Path $runtime 'cursor.json')
        rconHost = '127.0.0.1'
        rconPort = 34198
        rconPassword = ''
        rconTimeoutSeconds = 10
        replayExistingEvents = $false
        pollMilliseconds = 100
    }
    safety = @{ maxMineAmount = 100 }
} | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($bridgeConfig, $bridgeSettings, [Text.UTF8Encoding]::new($false))

$bridgeProject = Join-Path $projectRoot 'bridge\Alina.Bridge\Alina.Bridge.csproj'
Write-Host 'Собираю локальный bridge...' -ForegroundColor Cyan
& dotnet build $bridgeProject -c Release --nologo
if ($LASTEXITCODE -ne 0) { throw 'Bridge build failed.' }
$bridgeDll = Join-Path $projectRoot 'bridge\Alina.Bridge\bin\Release\net8.0\Alina.Bridge.dll'
if (-not (Test-Path -LiteralPath $bridgeDll)) { throw 'Собранный Alina.Bridge.dll не найден.' }

$bridge = $null
$client = $null
try {
    Remove-Item -LiteralPath (Join-Path $logs 'bridge.stdout.log'), (Join-Path $logs 'bridge.stderr.log') -Force -ErrorAction SilentlyContinue
    $bridge = Start-Process -FilePath 'dotnet' -ArgumentList ('"{0}" --config "{1}"' -f $bridgeDll, $bridgeConfig) `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $logs 'bridge.stdout.log') `
        -RedirectStandardError (Join-Path $logs 'bridge.stderr.log')

    Start-Sleep -Seconds 2
    if ($bridge.HasExited) {
        $errorText = Get-Content -LiteralPath (Join-Path $logs 'bridge.stderr.log') -Raw -ErrorAction SilentlyContinue
        throw "Alina Bridge не запустился. $errorText"
    }

    $clientArgs = '--mod-directory "{0}" --enable-lua-udp {1} --no-log-rotation' -f $modsRoot, $FactorioUdpPort
    if (-not $NewGame) {
        $clientArgs += ' --load-game "{0}"' -f $playableSave
    }

    if ($NewGame) {
        Write-Host 'Запускаю Factorio. Выбери Новая игра и создай мир обычным способом.' -ForegroundColor Cyan
    } else {
        Write-Host 'Запускаю Factorio с безопасной копией существующего сейва.' -ForegroundColor Cyan
    }
    Write-Host 'После загрузки мира Bridge в окне Алины должен стать connected.'
    $sessionStartedAt = Get-Date
    $client = Start-Process -FilePath $FactorioExe -ArgumentList $clientArgs -PassThru
    $client.WaitForExit()

    if (-not $NewGame) {
        # Если пользователь полагался только на штатный autosave, не теряем прогресс:
        # после закрытия Factorio переносим самый свежий autosave этой сессии в
        # постоянную безопасную копию Alina-Playable.zip. Перед заменой сохраняем backup.
        $recentAutosave = Get-ChildItem -LiteralPath $savesRoot -Filter '_autosave*.zip' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $sessionStartedAt } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($recentAutosave -and $recentAutosave.LastWriteTime -gt (Get-Item -LiteralPath $playableSave).LastWriteTime) {
            $saveBackup = Join-Path $runtime ('save-backups\Alina-Playable-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
            New-Item -ItemType Directory -Path (Split-Path -Parent $saveBackup) -Force | Out-Null
            Copy-Item -LiteralPath $playableSave -Destination $saveBackup -Force
            Copy-Item -LiteralPath $recentAutosave.FullName -Destination $playableSave -Force
            Write-Host "Сохранила последний autosave этой сессии в Alina-Playable.zip: $($recentAutosave.Name)" -ForegroundColor Green
        }
    }
} finally {
    if ($bridge -and -not $bridge.HasExited) {
        Stop-Process -Id $bridge.Id -Force -ErrorAction SilentlyContinue
    }
}

if ($NewGame) {
    Write-Host 'Factorio закрыта. Новая игра сохраняется обычным механизмом Factorio.' -ForegroundColor Green
} else {
    Write-Host 'Factorio закрыта. Прогресс сохранён в Alina-Playable.zip/автосейвах обычным механизмом игры.' -ForegroundColor Green
}
