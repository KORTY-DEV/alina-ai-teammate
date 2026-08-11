[CmdletBinding()]
param(
    [switch]$IncludeOllama,
    [switch]$SkipProjectTests
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$failed = $false

function Section([string]$name) {
    Write-Host "`n=== $name ===" -ForegroundColor Cyan
}

Section 'Repository sanity'
if (Get-Command git -ErrorAction SilentlyContinue) {
    git status --short
} else {
    Write-Warning 'git not found'
}

Section '.NET build'
$bridgeProject = Join-Path $root 'bridge\Alina.Bridge\Alina.Bridge.csproj'
if (Test-Path $bridgeProject) {
    & dotnet build $bridgeProject -c Release --nologo
    if ($LASTEXITCODE -ne 0) { $failed = $true }
} else {
    Write-Warning 'Bridge project not found'
    $failed = $true
}

Section '.NET contract tests'
$testProject = Join-Path $root 'bridge\Alina.Bridge.Tests\Alina.Bridge.Tests.csproj'
if (Test-Path $testProject) {
    & dotnet run --project $testProject -c Release
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}

if (-not $SkipProjectTests) {
    $projectTest = Join-Path $root 'scripts\Test-Project.ps1'
    if (Test-Path $projectTest) {
        Section 'Project test script'
        if ($IncludeOllama) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $projectTest -IncludeOllama
        } else {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $projectTest
        }
        if ($LASTEXITCODE -ne 0) { $failed = $true }
    }
}

Section 'Static high-risk regression checks'
$luaFiles = Get-ChildItem (Join-Path $root 'factorio-mod') -Recurse -Filter *.lua -ErrorAction SilentlyContinue
$runtimeRequireHits = @()
foreach ($f in $luaFiles) {
    $lines = Get-Content $f.FullName -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '\brequire\s*\(' -and $i -gt 40) {
            # Informational only: runtime require cannot be proven statically by line number.
            $runtimeRequireHits += "{0}:{1}: {2}" -f $f.FullName,($i+1),$lines[$i].Trim()
        }
    }
}
if ($runtimeRequireHits.Count -gt 0) {
    Write-Host 'Review require() locations (informational):'
    $runtimeRequireHits | Select-Object -First 50 | ForEach-Object { Write-Host $_ }
}

if ($IncludeOllama) {
    Section 'Ollama/GPU snapshot'
    if (Get-Command ollama -ErrorAction SilentlyContinue) { ollama ps; ollama list }
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { nvidia-smi }
}

if ($failed) {
    Write-Error 'QUALITY GATE FAILED'
    exit 1
}
Write-Host "`nQUALITY GATE PASSED" -ForegroundColor Green
exit 0
