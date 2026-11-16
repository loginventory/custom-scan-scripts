<#
.SYNOPSIS
    Builds the catalog package: scripts-catalog-<version>.zip with the content of catalog/,
    catalog.json and catalog.cat.
.DESCRIPTION
    The package is what the Remote Scanner imports (from a file, a company share, later online).
    Its layout is the Agents folder itself, plus catalog.json (the index with all manifests and
    SHA-256 hashes) and catalog.cat (a Windows catalog file over every file, verified with
    Test-FileCatalog; the release pipeline will sign it later). Test-FileCatalog checks the
    staging folder before the zip is written.
.PARAMETER CatalogVersion
    Version of the catalog as a whole: YYYY.MM.n for releases (e.g. 2026.11.1), 0.0.0-dev locally.
.PARAMETER OutputDir
    Where the zip, catalog.json and the staging folder "package" are written (default: build/).
.EXAMPLE
    ./tools/New-CatalogPackage.ps1 -CatalogVersion 2026.11.1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+(-[a-z]+)?$')][string]$CatalogVersion,
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CatalogManifest.psm1') -Force

$catalogRoot = Get-CatalogRoot -RepoRoot $RepoRoot
$staging = Join-Path $OutputDir 'package'
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

# 1. The content of catalog/ as it is: the layout equals the Agents folder of the customer
Copy-Item -Path (Join-Path $catalogRoot '*') -Destination $staging -Recurse -Force

# 2. The index with the manifests and the hashes of every packaged file
& (Join-Path $PSScriptRoot 'New-CatalogIndex.ps1') -RepoRoot $RepoRoot -OutputPath (Join-Path $staging 'catalog.json') -CatalogVersion $CatalogVersion | Out-Null

# 3. Windows catalog file over everything in the package (SHA-256); created outside, then moved in
$catalogFile = Join-Path $OutputDir 'catalog.cat'
if (Test-Path -LiteralPath $catalogFile) { Remove-Item -LiteralPath $catalogFile -Force }
New-FileCatalog -Path $staging -CatalogFilePath $catalogFile -CatalogVersion 2 | Out-Null
Move-Item -LiteralPath $catalogFile -Destination (Join-Path $staging 'catalog.cat') -Force

# 4. Verify the staging folder against the catalog file before packing
$check = Test-FileCatalog -Path $staging -CatalogFilePath (Join-Path $staging 'catalog.cat') -FilesToSkip 'catalog.cat' -Detailed
if ($check.Status -ne 'Valid') {
    throw "catalog.cat does not match the package content ($($check.Status)): $(($check.CatalogItems.Keys + $check.PathItems.Keys | Sort-Object -Unique) -join ', ')"
}

# 5. Zip with forward slashes in the entry names, the file name carries the version
$zipPath = Join-Path $OutputDir "scripts-catalog-$CatalogVersion.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($staging, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
Copy-Item -LiteralPath (Join-Path $staging 'catalog.json') -Destination (Join-Path $OutputDir 'catalog.json') -Force

$files = @(Get-ChildItem -LiteralPath $staging -Recurse -File)
"package: $zipPath ($([math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB)) KB, $($files.Count) files, catalog $CatalogVersion)"
