[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

$ErrorActionPreference = 'Stop'
if (Get-Process factorio -ErrorAction SilentlyContinue) {
    throw 'Factorio is running. Close it yourself before installing the development mod.'
}

$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$source = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'factorio-mod\alina-ai-teammate_0.1.0'))
$modsRoot = [System.IO.Path]::GetFullPath((Join-Path $env:APPDATA 'Factorio\mods'))
$target = [System.IO.Path]::GetFullPath((Join-Path $modsRoot 'alina-ai-teammate_0.1.0'))

if (-not (Test-Path -LiteralPath $source)) { throw "Source mod not found: $source" }
if (-not (Test-Path -LiteralPath $modsRoot)) { throw "Factorio mods directory not found: $modsRoot" }
if (-not $target.StartsWith($modsRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unsafe Factorio mod target.'
}

$existing = Get-ChildItem -LiteralPath $modsRoot -Force | Where-Object { $_.Name -like 'alina-ai-teammate*' }
if ($existing.Count -gt 0) {
    $backupRoot = [System.IO.Path]::GetFullPath((Join-Path $modsRoot ('.alina-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))))
    if (-not $backupRoot.StartsWith($modsRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe backup target.'
    }
    if ($PSCmdlet.ShouldProcess($backupRoot, 'Back up existing Alina mod packages')) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        foreach ($item in $existing) {
            Move-Item -LiteralPath $item.FullName -Destination $backupRoot
        }
        Write-Output "Previous Alina packages moved to $backupRoot"
    }
}

if ($PSCmdlet.ShouldProcess($target, 'Install Alina development mod')) {
    Copy-Item -LiteralPath $source -Destination $target -Recurse
    Write-Output "Installed development mod to $target"
    Write-Output 'Enable alina-ai-teammate in the Factorio mod UI; mod-list.json was not edited.'
}

