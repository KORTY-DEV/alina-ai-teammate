[CmdletBinding()]
param(
    [switch]$IncludeDiff,
    [switch]$RunQualityGate,
    [int]$TailLines = 1200
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$diagRoot = Join-Path $root 'diagnostics'
$latest = Join-Path $diagRoot 'latest'
$tmp = Join-Path $diagRoot ('handoff-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Save-Command([string]$name, [scriptblock]$cmd) {
    $path = Join-Path $tmp $name
    try { & $cmd 2>&1 | Out-File -FilePath $path -Encoding utf8 } catch { $_ | Out-File -FilePath $path -Encoding utf8 }
}
function Copy-Tail([string]$source, [string]$name) {
    if (Test-Path $source) {
        Get-Content $source -Tail $TailLines -ErrorAction SilentlyContinue | Out-File (Join-Path $tmp $name) -Encoding utf8
    }
}
function Copy-If([string]$source, [string]$destName) {
    if (Test-Path $source) { Copy-Item $source (Join-Path $tmp $destName) -Force }
}

$timestamp = Get-Date -Format o
@"
Alina AI Teammate diagnostic handoff
Generated: $timestamp
Project: $root
This bundle intentionally excludes saves by default.
"@ | Out-File (Join-Path $tmp 'HANDOFF.txt') -Encoding utf8

Save-Command 'git-status.txt' { git status --short --branch }
Save-Command 'git-log.txt' { git log -n 20 --oneline --decorate }
Save-Command 'git-diff-stat.txt' { git diff --stat }
if ($IncludeDiff) { Save-Command 'git-diff.patch' { git diff --no-ext-diff --binary } }
Save-Command 'dotnet-info.txt' { dotnet --info }
Save-Command 'ollama-list.txt' { ollama list }
Save-Command 'ollama-ps.txt' { ollama ps }
Save-Command 'nvidia-smi.txt' { nvidia-smi }
Save-Command 'processes.txt' { Get-Process | Sort-Object CPU -Descending | Select-Object -First 80 Name,Id,CPU,WorkingSet64,Path | Format-Table -AutoSize }

$runtimeLogs = Join-Path $root '.alina-runtime\logs'
Copy-Tail (Join-Path $runtimeLogs 'bridge.stdout.log') 'bridge.stdout.tail.log'
Copy-Tail (Join-Path $runtimeLogs 'bridge.stderr.log') 'bridge.stderr.tail.log'
Copy-Tail (Join-Path $runtimeLogs 'launcher.log') 'launcher.tail.log'

$factorioData = Join-Path $env:APPDATA 'Factorio'
Copy-Tail (Join-Path $factorioData 'factorio-current.log') 'factorio-current.tail.log'
Copy-Tail (Join-Path $factorioData 'factorio-previous.log') 'factorio-previous.tail.log'

$eventCandidates = @(
    (Join-Path $factorioData 'script-output\alina\events.jsonl'),
    (Join-Path $factorioData 'script-output\alina\telemetry.jsonl'),
    (Join-Path $root '.alina-runtime\script-output\alina\events.jsonl'),
    (Join-Path $root '.alina-runtime\script-output\alina\telemetry.jsonl')
)
$i = 0
foreach ($p in $eventCandidates) {
    if (Test-Path $p) { $i++; Copy-Tail $p ("alina-events-$i.tail.jsonl") }
}

Copy-If (Join-Path $root 'PACKAGE_VERSION.txt') 'PACKAGE_VERSION.txt'
Copy-If (Join-Path $root 'docs\CURRENT_STATUS.md') 'CURRENT_STATUS.md'
Copy-If (Join-Path $root 'bridge\appsettings.example.json') 'appsettings.example.json'

$localCfg = Join-Path $root 'bridge\appsettings.local.json'
if (Test-Path $localCfg) {
    try {
        $text = Get-Content $localCfg -Raw
        $text = $text -replace '(?i)("(?:password|token|secret|api[_-]?key)"\s*:\s*")[^"]*(")', '$1<redacted>$2'
        $text | Out-File (Join-Path $tmp 'appsettings.local.sanitized.json') -Encoding utf8
    } catch {}
}

if ($RunQualityGate) {
    $qg = Join-Path $tmp 'quality-gate.txt'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Run-QualityGate.ps1') 2>&1 | Tee-Object -FilePath $qg
    $qgExit = $LASTEXITCODE
    "quality_gate_exit=$qgExit" | Out-File (Join-Path $tmp 'quality-gate-exit.txt') -Encoding ascii
}

# Capture recent crash/desync report names without copying potentially huge archives.
$crashCandidates = Get-ChildItem $factorioData -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '(desync|crash|dump)' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 20 FullName,Length,LastWriteTime
$crashCandidates | Format-Table -AutoSize | Out-File (Join-Path $tmp 'recent-crash-desync-files.txt') -Encoding utf8

if (Test-Path $latest) { Remove-Item $latest -Recurse -Force }
New-Item -ItemType Directory -Force -Path $latest | Out-Null
Copy-Item (Join-Path $tmp '*') $latest -Recurse -Force
$zip = Join-Path $latest 'Alina-Handoff.zip'
$zipStaging = Join-Path $diagRoot ('zip-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $zipStaging | Out-Null
Copy-Item (Join-Path $tmp '*') $zipStaging -Recurse -Force
Compress-Archive -Path (Join-Path $zipStaging '*') -DestinationPath $zip -CompressionLevel Optimal -Force
Remove-Item $zipStaging -Recurse -Force

Write-Host "Diagnostics ready: $zip" -ForegroundColor Green
Write-Host 'Upload this ZIP for review.'
