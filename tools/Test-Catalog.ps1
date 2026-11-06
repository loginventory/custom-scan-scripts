<#
.SYNOPSIS
    Checks the script catalog (catalog/) against the rules of this repository.
.DESCRIPTION
    Run it locally before a pull request; the CI workflow runs it on every push and pull request.
    Exits with 1 if any check fails. Checks:
      - every script in catalog/ starts with an LI-MANIFEST comment block that is valid JSON and matches tools/manifest.schema.json
      - ids are unique, the script uses the current header (New-CommonContext)
      - the parameters in the manifest are exactly the keys the script reads from $ctx.UserParameters
      - sub folders listed under "files" exist, and every sub folder in catalog/ belongs to a script
      - presets only set declared parameters with allowed values
      - the tier in the manifest matches .github/CODEOWNERS
      - catalog/retired.json is consistent
      - published file names are stable (needs -BaselineCatalogPath, the catalog.json of the last release)
      - no hard-coded credentials
      - PSScriptAnalyzer reports no errors
.PARAMETER BaselineCatalogPath
    catalog.json of the last release. Every script published there must still exist under the same
    file name with the same id, or be listed in catalog/retired.json.
.PARAMETER SkipScriptAnalyzer
    Skip the PSScriptAnalyzer run (for a quick local check when the module is not installed).
.EXAMPLE
    ./tools/Test-Catalog.ps1
.EXAMPLE
    ./tools/Test-Catalog.ps1 -BaselineCatalogPath build/catalog.json
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$BaselineCatalogPath,
    [switch]$SkipScriptAnalyzer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CatalogManifest.psm1') -Force

$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string]$Message) { $script:failures.Add($Message); Write-Host "FAIL  $Message" -ForegroundColor Red }
function Pass([string]$Message) { Write-Host "ok    $Message" -ForegroundColor Green }
function Info([string]$Message) { Write-Host "info  $Message" -ForegroundColor Yellow }
function Get-RelativePath([string]$Path) { return $Path.Substring($RepoRoot.Length).TrimStart('\', '/').Replace('\', '/') }

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$catalogRoot = Get-CatalogRoot -RepoRoot $RepoRoot
$schemaPath = Join-Path $PSScriptRoot 'manifest.schema.json'
$scripts = @(Get-CatalogScript -RepoRoot $RepoRoot)

Write-Host "Catalog: $catalogRoot ($($scripts.Count) scripts)"
if ($scripts.Count -eq 0) { Fail 'no scripts found in catalog/' }

# --- Manifest present, valid JSON, valid against the schema, current header ---------------------
$valid = [System.Collections.Generic.List[object]]::new()
foreach ($s in $scripts) {
    if (-not $s.Json) { Fail "$($s.File): no <# LI-MANIFEST ... #> block at the top of the script"; continue }
    if ($s.ParseError) { Fail "$($s.File): manifest is not valid JSON ($($s.ParseError))"; continue }
    try {
        $null = Test-Json -Json $s.Json -SchemaFile $schemaPath -ErrorAction Stop
    }
    catch {
        Fail "$($s.File): manifest violates the schema: $($_.Exception.Message)"
        continue
    }
    if (-not $s.UsesCommonContext) { Fail "$($s.File): script must use the current header (New-CommonContext)" }
    # The Remote Scanner service hands the raw block to the client over WCF (8192 characters per string)
    if ($s.Json.Length -gt 7500) { Fail "$($s.File): manifest block has $($s.Json.Length) characters, at most 7500 are allowed" }
    $valid.Add($s)
    Pass "$($s.File): manifest valid (id $($s.Manifest.id), version $($s.Manifest.version), tier $($s.Manifest.tier))"
}

# --- Unique ids --------------------------------------------------------------------------------
foreach ($g in ($valid | Group-Object { $_.Manifest.id } | Where-Object Count -gt 1)) {
    Fail "id '$($g.Name)' is used by several scripts: $(($g.Group | ForEach-Object File) -join ', ')"
}

# --- Parameters: manifest vs. script, presets --------------------------------------------------
foreach ($s in $valid) {
    $declared = @($s.Manifest.parameters | ForEach-Object { $_.name })
    $read = @($s.ParameterReads)
    foreach ($n in $read) {
        if (-not ($declared | Where-Object { $_ -ieq $n })) { Fail "$($s.File): script reads parameter '$n' that is not declared in the manifest" }
    }
    foreach ($n in $declared) {
        if (-not ($read | Where-Object { $_ -ieq $n })) { Fail "$($s.File): manifest declares parameter '$n' that the script never reads" }
    }
    foreach ($d in $s.Manifest.parameters) {
        if ($d.type -ne 'enum') { continue }
        $default = Get-ManifestValue -Object $d -Name 'default'
        if ($null -ne $default -and -not (@($d.options) -contains "$default")) { Fail "$($s.File): default '$default' of parameter '$($d.name)' is not one of its options" }
    }
    foreach ($p in @(Get-ManifestValue -Object $s.Manifest -Name 'presets' -Default @())) {
        foreach ($prop in $p.parameters.PSObject.Properties) {
            $decl = $s.Manifest.parameters | Where-Object { $_.name -ieq $prop.Name } | Select-Object -First 1
            if (-not $decl) { Fail "$($s.File): preset '$($p.id)' sets unknown parameter '$($prop.Name)'"; continue }
            if ($decl.type -eq 'enum' -and -not (@($decl.options) -contains "$($prop.Value)")) { Fail "$($s.File): preset '$($p.id)' sets '$($prop.Name)' to '$($prop.Value)', which is not one of its options" }
        }
    }
}

# --- Additional files: listed folders exist, every folder belongs to a script ------------------
$claimedFolders = @{}
foreach ($s in $valid) {
    foreach ($f in @(Get-ManifestValue -Object $s.Manifest -Name 'files' -Default @())) {
        $dir = Join-Path $catalogRoot $f.TrimEnd('/')
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Fail "$($s.File): files entry '$f' does not exist in catalog/" }
        if ($claimedFolders.ContainsKey($f)) { Fail "'$f' is listed under files by $($claimedFolders[$f]) and $($s.File)" }
        else { $claimedFolders[$f] = $s.File }
    }
}
foreach ($dir in Get-ChildItem -LiteralPath $catalogRoot -Directory) {
    if ($dir.Name -in 'include', 'icons') { continue }
    if (-not $claimedFolders.ContainsKey("$($dir.Name)/")) { Fail "catalog/$($dir.Name)/ is not listed under 'files' in any manifest" }
}
foreach ($file in Get-ChildItem -LiteralPath $catalogRoot -File) {
    if ($file.Extension -ne '.ps1' -and $file.Name -ne 'retired.json') { Fail "catalog/$($file.Name): only scripts (*.ps1) and retired.json belong directly into catalog/" }
}

# --- Tier vs. CODEOWNERS -----------------------------------------------------------------------
$codeOwnersPath = Join-Path $RepoRoot '.github/CODEOWNERS'
if (-not (Test-Path -LiteralPath $codeOwnersPath)) {
    Fail '.github/CODEOWNERS is missing'
}
else {
    $rules = Get-CodeOwnerRules -Path $codeOwnersPath
    $baseRule = $rules | Where-Object { $_.Pattern -in '/catalog/', 'catalog/' } | Select-Object -Last 1
    if (-not $baseRule) {
        Fail 'CODEOWNERS needs a rule for /catalog/ that names the LOGIN owners'
    }
    else {
        $loginOwners = @($baseRule.Owners)
        function Test-TierOwners([string]$RelativePath, [string]$Tier, [string]$Script) {
            # A folder is matched through a file inside it, like GitHub does
            $matchPath = if ($RelativePath.EndsWith('/')) { $RelativePath + 'file' } else { $RelativePath }
            $owners = Get-EffectiveCodeOwners -Rules $rules -RelativePath $matchPath
            $extra = @($owners | Where-Object { $_ -notin $loginOwners })
            $missing = @($loginOwners | Where-Object { $_ -notin $owners })
            if ($missing.Count -gt 0) { Fail "$RelativePath (tier $Tier): CODEOWNERS must keep the LOGIN owners ($($loginOwners -join ' ')), found: $($owners -join ' ')"; return }
            switch ($Tier) {
                'partner' { if ($extra.Count -eq 0) { Info "$RelativePath (tier partner): no partner account in CODEOWNERS yet" } }
                default { if ($extra.Count -gt 0) { Fail "$RelativePath (tier $Tier): only tier 'partner' may have owners besides the LOGIN team, found: $($extra -join ' ')" } }
            }
        }
        foreach ($s in $valid) {
            Test-TierOwners -RelativePath "catalog/$($s.File)" -Tier $s.Manifest.tier -Script $s.File
            foreach ($f in @(Get-ManifestValue -Object $s.Manifest -Name 'files' -Default @())) {
                Test-TierOwners -RelativePath "catalog/$f" -Tier $s.Manifest.tier -Script $s.File
            }
        }
        Test-TierOwners -RelativePath 'catalog/include/common.ps1' -Tier 'login' -Script 'include'
        Test-TierOwners -RelativePath 'catalog/retired.json' -Tier 'login' -Script 'retired.json'
        Pass "tiers match CODEOWNERS (LOGIN owners: $($loginOwners -join ' '))"
    }
}

# --- retired.json ------------------------------------------------------------------------------
$retired = @()
$retiredPath = Join-Path $catalogRoot 'retired.json'
if (-not (Test-Path -LiteralPath $retiredPath)) {
    Fail 'catalog/retired.json is missing (an empty list [] is fine)'
}
else {
    try { $retired = @(Get-Content -LiteralPath $retiredPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Fail "catalog/retired.json is not valid JSON ($($_.Exception.Message))" }
    foreach ($r in $retired) {
        foreach ($name in 'id', 'file', 'since', 'reason') {
            if ($null -eq (Get-ManifestValue -Object $r -Name $name)) { Fail "retired.json: entry without '$name'" }
        }
        $reason = Get-ManifestValue -Object $r -Name 'reason'
        if ($reason -and ($null -eq (Get-ManifestValue -Object $reason -Name 'de') -or $null -eq (Get-ManifestValue -Object $reason -Name 'en'))) { Fail "retired.json: '$(Get-ManifestValue -Object $r -Name 'id')' needs reason.de and reason.en" }
        $file = Get-ManifestValue -Object $r -Name 'file'
        if ($file -and (Test-Path -LiteralPath (Join-Path $catalogRoot $file))) { Fail "retired.json lists '$file', but the file still exists in catalog/" }
        $id = Get-ManifestValue -Object $r -Name 'id'
        if ($id -and ($valid | Where-Object { $_.Manifest.id -eq $id })) { Fail "retired.json lists id '$id', but a script in catalog/ still uses it" }
    }
    Pass "retired.json valid ($($retired.Count) entries)"
}

# --- Stable file names against the last release ------------------------------------------------
if ($BaselineCatalogPath) {
    if (-not (Test-Path -LiteralPath $BaselineCatalogPath)) {
        Fail "baseline catalog not found: $BaselineCatalogPath"
    }
    else {
        $baseline = Get-Content -LiteralPath $BaselineCatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($b in @($baseline.scripts)) {
            $current = $valid | Where-Object { $_.File -eq $b.file } | Select-Object -First 1
            $isRetired = $retired | Where-Object { (Get-ManifestValue -Object $_ -Name 'file') -eq $b.file }
            if (-not $current -and -not $isRetired) { Fail "published script '$($b.file)' (id $($b.id)) was removed or renamed; definitions store the full path, so keep the file name or list it in retired.json" }
            if ($current -and $current.Manifest.id -ne $b.id) { Fail "published script '$($b.file)' changed its id from '$($b.id)' to '$($current.Manifest.id)'" }
        }
        Pass "file names stable against release $($baseline.catalogVersion)"
    }
}
else {
    Info 'no baseline catalog.json given, stable file name check skipped'
}

# --- Hard-coded credentials --------------------------------------------------------------------
$credentialRegex = [regex]'(?i)(secret|password|passwd|apikey|api_key|accesstoken|access_token|token)\s*=\s*["''][^"'']{6,}["'']'
foreach ($file in Get-ChildItem -LiteralPath $catalogRoot -Recurse -Filter *.ps1 -File) {
    $inBlockComment = $false
    $lineNo = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8) {
        $lineNo++
        if ($inBlockComment) { if ($line -match '#>') { $inBlockComment = $false }; continue }
        if ($line -match '^\s*<#') { if ($line -notmatch '#>') { $inBlockComment = $true }; continue }
        if ($line -match '^\s*#') { continue }
        if ($credentialRegex.IsMatch($line) -and $line -notmatch 'UserParameters|\$ctx\.|\$env:') {
            Fail "$(Get-RelativePath $file.FullName):$lineNo looks like a hard-coded credential: $($line.Trim())"
        }
    }
}

# --- PSScriptAnalyzer --------------------------------------------------------------------------
if ($SkipScriptAnalyzer) {
    Info 'PSScriptAnalyzer skipped'
}
elseif (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Fail 'PSScriptAnalyzer is not installed (Install-Module PSScriptAnalyzer -Scope CurrentUser) or pass -SkipScriptAnalyzer'
}
else {
    Import-Module PSScriptAnalyzer
    $findings = @(Invoke-ScriptAnalyzer -Path $catalogRoot -Recurse -Severity Error)
    foreach ($f in $findings) { Fail "$(Get-RelativePath $f.ScriptPath):$($f.Line) $($f.RuleName): $($f.Message)" }
    if ($findings.Count -eq 0) { Pass 'PSScriptAnalyzer: no errors' }
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All catalog checks passed' -ForegroundColor Green
exit 0
