[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$source = Join-Path $projectRoot 'factorio-mod\alina-ai-teammate_0.1.0'
$dist = Join-Path $projectRoot 'dist'
$archive = Join-Path $dist 'alina-ai-teammate_0.1.0.zip'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [System.IO.File]::Open($archive, [System.IO.FileMode]::CreateNew)
$zip = $null
try {
    $zip = [System.IO.Compression.ZipArchive]::new(
        $stream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $false,
        [System.Text.Encoding]::UTF8)
    $sourceParent = Split-Path -Parent $source
    foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File | Sort-Object FullName) {
        $entryName = $file.FullName.Substring($sourceParent.Length + 1).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip,
            $file.FullName,
            $entryName,
            [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    if ($zip) { $zip.Dispose() }
    $stream.Dispose()
}
Get-Item -LiteralPath $archive | Select-Object FullName, Length, LastWriteTime
