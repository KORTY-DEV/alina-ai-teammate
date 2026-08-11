[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$factorioRoot = Join-Path $env:APPDATA 'Factorio'
$logPath = Join-Path $factorioRoot 'factorio-current.log'
$modListPath = Join-Path $factorioRoot 'mods\mod-list.json'

Write-Output '=== Factorio ==='
if (Test-Path -LiteralPath $logPath) {
    Select-String -LiteralPath $logPath -Pattern 'Factorio [0-9]|Program arguments:|Read data path:|Write data path:' |
        Select-Object -First 4 |
        ForEach-Object Line
}
if (Test-Path -LiteralPath $modListPath) {
    $mods = (Get-Content -LiteralPath $modListPath -Raw | ConvertFrom-Json).mods
    Write-Output ("Active mods: " + (($mods | Where-Object enabled).Count))
}
Get-Process factorio -ErrorAction SilentlyContinue | Select-Object Id, Path, StartTime, CPU, WorkingSet64

Write-Output '=== Ollama ==='
ollama --version
ollama list
ollama ps

Write-Output '=== GPU ==='
nvidia-smi

Write-Output '=== Toolchain ==='
git --version
dotnet --info

