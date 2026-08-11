$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$required = @(
  'START_ALINA_PLAYABLE.cmd',
  'scripts\Start-AlinaPlayable.ps1',
  'bridge\Alina.Bridge\Alina.Bridge.csproj',
  'bridge\Alina.Bridge\BridgeWorker.cs',
  'bridge\Alina.Bridge\Factorio\UdpFactorioTransport.cs',
  'factorio-mod\alina-ai-teammate_0.1.0\control.lua',
  'factorio-mod\alina-ai-teammate_0.1.0\scripts\sensors\world_model.lua',
  'factorio-mod\alina-ai-teammate_0.1.0\scripts\gui\panel.lua'
)
foreach ($rel in $required) {
  $path = Join-Path $root $rel
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing required file: $rel" }
}
Get-Content -LiteralPath (Join-Path $root 'bridge\appsettings.example.json') -Raw | ConvertFrom-Json | Out-Null
Get-Content -LiteralPath (Join-Path $root 'factorio-mod\mod-list.json') -Raw | ConvertFrom-Json | Out-Null
Get-Content -LiteralPath (Join-Path $root 'schemas\protocol-v1.schema.json') -Raw | ConvertFrom-Json | Out-Null
Write-Host 'Consolidated package structure and JSON: OK' -ForegroundColor Green
