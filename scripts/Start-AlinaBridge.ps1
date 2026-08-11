[CmdletBinding()]
param(
    [string]$Config = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bridge\appsettings.local.json')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Config)) {
    throw "Bridge config not found: $Config"
}

$projectRoot = Split-Path -Parent $PSScriptRoot
& dotnet run --project (Join-Path $projectRoot 'bridge\Alina.Bridge') --configuration Release -- --config $Config
exit $LASTEXITCODE
