# Helpers shared by the catalog tools: reads the LI-MANIFEST blocks of the scripts in catalog/,
# the parameter names a script reads and the rules of .github/CODEOWNERS.
Set-StrictMode -Version Latest

$script:ManifestRegex = [regex]::new('<#\s*LI-MANIFEST\s*\r?\n(?<json>.*?)\r?\n\s*#>', 'Singleline')
$script:ParameterReadRegex = [regex]::new('UserParameters\s*(?:\[\s*["'']([^"'']+)["'']\s*\]|\.([A-Za-z_][A-Za-z0-9_]*))')
$script:HashtableMembers = @('Keys', 'Values', 'Count', 'Contains', 'ContainsKey', 'GetEnumerator', 'Remove', 'Add', 'Clone', 'PSObject', 'GetType')

function Get-CatalogRoot {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return (Join-Path $RepoRoot 'catalog')
}

function Get-ManifestJson {
    # Returns the JSON text of the first <# LI-MANIFEST ... #> block, or $null.
    param([Parameter(Mandatory)][string]$Path)
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $m = $script:ManifestRegex.Match($content)
    if (-not $m.Success) { return $null }
    return $m.Groups['json'].Value
}

function Get-ManifestValue {
    # Reads an optional property of a parsed manifest without tripping Set-StrictMode.
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function Get-ScriptParameterReads {
    # Names the script reads from $ctx.UserParameters ("key" or .key), in order of first use.
    param([Parameter(Mandatory)][string]$Path)
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $script:ParameterReadRegex.Matches($content)) {
        $n = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        if ($script:HashtableMembers -contains $n) { continue }
        if (-not ($names | Where-Object { $_ -ieq $n })) { $names.Add($n) }
    }
    return $names.ToArray()
}

function Get-CatalogScript {
    # One object per script directly in catalog/ (sub folders and include/ are not scripts of their own).
    param([Parameter(Mandatory)][string]$RepoRoot)
    $catalog = Get-CatalogRoot -RepoRoot $RepoRoot
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $catalog -Filter *.ps1 -File | Sort-Object Name) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        $json = Get-ManifestJson -Path $file.FullName
        $manifest = $null
        $parseError = $null
        if ($json) {
            try { $manifest = $json | ConvertFrom-Json -Depth 10 }
            catch { $parseError = $_.Exception.Message }
        }
        $result.Add([pscustomobject]@{
            File              = $file.Name
            Path              = $file.FullName
            Json              = $json
            Manifest          = $manifest
            ParseError        = $parseError
            UsesCommonContext = ($content -match 'New-CommonContext')
            ParameterReads    = @(Get-ScriptParameterReads -Path $file.FullName)
        })
    }
    return $result.ToArray()
}

function ConvertTo-CodeOwnerRegex {
    # Simplified CODEOWNERS pattern matching (gitignore style): leading "/" anchors at the repo root,
    # a pattern with "/" inside is anchored too, trailing "/" matches the folder content, "*" never crosses "/".
    param([Parameter(Mandatory)][string]$Pattern)
    if ($Pattern -eq '*') { return [regex]'^.*$' }
    $p = $Pattern
    $anchored = $p.StartsWith('/') -or $p.TrimEnd('/').Contains('/')
    $p = $p.TrimStart('/')
    $dirOnly = $p.EndsWith('/')
    $p = $p.TrimEnd('/')
    $esc = [regex]::Escape($p) -replace '\\\*\\\*', '.*' -replace '\\\*', '[^/]*' -replace '\\\?', '[^/]'
    $prefix = if ($anchored) { '^' } else { '^(?:.*/)?' }
    $suffix = if ($dirOnly) { '/.*$' } else { '(?:/.*)?$' }
    return [regex]($prefix + $esc + $suffix)
}

function Get-CodeOwnerRules {
    param([Parameter(Mandatory)][string]$Path)
    $rules = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = ($raw -replace '#.*$', '').Trim()
        if (-not $line) { continue }
        $parts = $line -split '\s+'
        $rules.Add([pscustomobject]@{
            Pattern = $parts[0]
            Owners  = @($parts | Select-Object -Skip 1)
            Regex   = ConvertTo-CodeOwnerRegex -Pattern $parts[0]
        })
    }
    return ,$rules
}

function Get-EffectiveCodeOwners {
    # Owners of a repo-relative path (forward slashes): the last matching rule wins, like on GitHub.
    param([Parameter(Mandatory)]$Rules, [Parameter(Mandatory)][string]$RelativePath)
    $owners = @()
    foreach ($r in $Rules) {
        if ($r.Regex.IsMatch($RelativePath)) { $owners = $r.Owners }
    }
    return ,@($owners)
}

Export-ModuleMember -Function Get-CatalogRoot, Get-ManifestJson, Get-ManifestValue, Get-ScriptParameterReads, Get-CatalogScript, ConvertTo-CodeOwnerRegex, Get-CodeOwnerRules, Get-EffectiveCodeOwners
