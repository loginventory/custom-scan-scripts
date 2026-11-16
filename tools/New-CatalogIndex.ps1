<#
.SYNOPSIS
    Builds catalog.json, the index of the catalog, from the manifests and files in catalog/.
.DESCRIPTION
    The index lists every script with its manifest, file name and SHA-256 hash, the files of
    include/ and the retired scripts. The release pipeline ships it inside the catalog package;
    Test-Catalog.ps1 uses the index of the last release as baseline for the stable file name check.
.PARAMETER CatalogVersion
    Version of the catalog as a whole (YYYY.MM.n for releases). Defaults to 0.0.0-dev for local builds.
.EXAMPLE
    ./tools/New-CatalogIndex.ps1 -OutputPath build/catalog.json -CatalogVersion 2026.11.1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build/catalog.json'),
    [string]$CatalogVersion = '0.0.0-dev'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CatalogManifest.psm1') -Force

$catalogRoot = Get-CatalogRoot -RepoRoot $RepoRoot

function Get-FileEntry([string]$Path) {
    $relative = $Path.Substring($catalogRoot.Length).TrimStart('\', '/').Replace('\', '/')
    return [ordered]@{
        path   = $relative
        size   = (Get-Item -LiteralPath $Path).Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$scripts = foreach ($s in @(Get-CatalogScript -RepoRoot $RepoRoot)) {
    if (-not $s.Manifest -or $s.ParseError) { throw "$($s.File): missing or invalid manifest, run Test-Catalog.ps1 first" }
    $entry = [ordered]@{ file = $s.File }
    foreach ($p in $s.Manifest.PSObject.Properties) { $entry[$p.Name] = $p.Value }
    $entryFiles = [System.Collections.Generic.List[object]]::new()
    $entryFiles.Add((Get-FileEntry $s.Path))
    foreach ($folder in @(Get-ManifestValue -Object $s.Manifest -Name 'files' -Default @())) {
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $catalogRoot $folder.TrimEnd('/')) -Recurse -File) { $entryFiles.Add((Get-FileEntry $f.FullName)) }
    }
    $entry['package'] = $entryFiles.ToArray()
    $entry
}

$include = foreach ($f in Get-ChildItem -LiteralPath (Join-Path $catalogRoot 'include') -Recurse -File) { Get-FileEntry $f.FullName }

$retiredPath = Join-Path $catalogRoot 'retired.json'
$retired = if (Test-Path -LiteralPath $retiredPath) { @(Get-Content -LiteralPath $retiredPath -Raw -Encoding UTF8 | ConvertFrom-Json) } else { @() }

$index = [ordered]@{
    schema         = 1
    catalogVersion = $CatalogVersion
    generated      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    scripts        = @($scripts)
    include        = @($include)
    retired        = @($retired)
}

$dir = Split-Path -Parent $OutputPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllText($OutputPath, ($index | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
Write-Host "catalog index written: $OutputPath ($(@($scripts).Count) scripts, version $CatalogVersion)"
