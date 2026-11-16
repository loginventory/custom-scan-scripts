<#
.SYNOPSIS
    Generates the script table in readme.md from the manifests in catalog/.
.DESCRIPTION
    Replaces everything between <!-- catalog:begin --> and <!-- catalog:end --> in readme.md.
    With -Check nothing is written; the script exits with 1 if the table is out of date (used by CI).
.EXAMPLE
    ./tools/Update-Readme.ps1
.EXAMPLE
    ./tools/Update-Readme.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CatalogManifest.psm1') -Force

$createsLabel = @{
    Assets           = 'Assets'
    SoftwarePackages = 'Software-Pakete'
    Subscriptions    = 'Cloud-Subscriptions'
    Licenses         = 'Lizenzen'
    UserAccounts     = 'Benutzerkonten'
    CustomProperties = 'Eigene Eigenschaften'
    Vulnerabilities  = 'Schwachstellen'
}
$tierLabel = @{ login = 'LOGIN'; partner = 'Partner'; community = 'Community' }

function Escape-Cell([string]$Text) { return ($Text -replace '\|', '\|') }

$scripts = @(Get-CatalogScript -RepoRoot $RepoRoot | Where-Object { $_.Manifest -and -not $_.ParseError })
$rows = [System.Collections.Generic.List[string]]::new()
$rows.Add('<!-- Erzeugt von tools/Update-Readme.ps1 aus den Manifesten in catalog/, nicht von Hand ändern -->')
$rows.Add('Skript | Beschreibung | Was wird in LOGINventory erzeugt? | Stufe | Version')
$rows.Add('-------|--------------|-----------------------------------|-------|--------')
foreach ($s in $scripts) {
    $m = $s.Manifest
    $description = $m.summary.de
    $files = @(Get-ManifestValue -Object $m -Name 'files' -Default @())
    if ($files.Count -gt 0) { $description += ' Benötigt zusätzlich den Ordner ' + (($files | ForEach-Object { "[$_](catalog/$_)" }) -join ', ') + '.' }
    $engine = if ($m.engine -eq 'psc') { ' Läuft mit der LOGINventory PowerShell (`engine` = `psc.exe`).' } else { '' }
    $creates = ($m.creates | ForEach-Object { $createsLabel[$_] }) -join ', '
    $tier = $tierLabel[$m.tier]
    if ($m.tier -eq 'partner') { $partner = Get-ManifestValue -Object $m -Name 'partner'; if ($partner) { $tier += " ($($partner.name))" } }
    $rows.Add(('[{0}](catalog/{0}) | **{1}**: {2}{3} | {4} | {5} | {6}' -f $s.File, (Escape-Cell $m.title.de), (Escape-Cell $description), $engine, $creates, $tier, $m.version))
}
$table = $rows -join "`r`n"

$readmePath = Join-Path $RepoRoot 'readme.md'
$readme = [IO.File]::ReadAllText($readmePath)
$pattern = '(?s)(<!-- catalog:begin -->).*?(<!-- catalog:end -->)'
if ($readme -notmatch $pattern) { throw 'readme.md has no <!-- catalog:begin --> / <!-- catalog:end --> markers' }
$updated = [regex]::Replace($readme, $pattern, { param($m) $m.Groups[1].Value + "`r`n" + $table + "`r`n" + $m.Groups[2].Value })

if (($updated -replace '\r\n', "`n") -eq ($readme -replace '\r\n', "`n")) {
    Write-Host 'readme.md is up to date'
    exit 0
}
if ($Check) {
    Write-Host 'readme.md is out of date: run tools/Update-Readme.ps1 and commit the result' -ForegroundColor Red
    exit 1
}
[IO.File]::WriteAllText($readmePath, $updated, [Text.UTF8Encoding]::new($false))
Write-Host "readme.md updated ($($scripts.Count) scripts)"
exit 0
