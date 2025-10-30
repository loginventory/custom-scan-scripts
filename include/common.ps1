<#
    File:        common.ps1
    Purpose:     Shared helpers for parameter encoding/decoding, config resolution,
                 XML serialization of inventory entities, proxy handling, and debug logging.

    Contents (selected):
      - Encode / Decode / EnsureEncodedParameters / Init
      - Inventory entity helpers: NewEntity, AddPropertyValue, WriteInv, ConvertTo-Xml, PostProcessXml
      - Config helpers: Get-LoginventoryConfigPath, Get-LoginventoryConfigSettings,
                        Merge-ParameterScopes, Get-EffectiveValue, Resolve-CommonEffectiveConfig,
                        New-CommonContext
      - Utilities: Join-Url, HasValue, ConvertTo-Bool (twice defined in source; see note below),
                   GetAllPropertyValuesAsString, Notify, New-SafeFileName

    Notes:
      - The script currently defines ConvertTo-Bool twice (different signatures). In PowerShell,
        the later definition overrides the earlier one. If that is unintended, consider renaming
        or removing one of them. I did NOT change this to preserve behavior.
      - Functions write minimal output; for diagnostics prefer DebugFile + Write-CommonDebug.

    Requirements:
      - Windows PowerShell 5.1 or PowerShell 7+

    Last Updated: 2025-09-26
#>

# Reserved variables (global to this module)
$lEntities = New-Object System.Collections.ArrayList

function Decode {
    <#
    .SYNOPSIS
        Base64-decodes a UTF-8 string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$value
    )
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($value))
}

function Encode {
    <#
    .SYNOPSIS
        Encodes a "key,value" pair where the value part is Base64-encoded (UTF-8).
    .DESCRIPTION
        Expects input in the form: "<key>,<plainValue>" and returns "<key>,<base64(value)>".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$value
    )
    $paramPair = $value -split ','
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($paramPair[1])
    return $paramPair[0] + ',' + [Convert]::ToBase64String($bytes)
}

function EnsureEncodedParameters {
    <#
    .SYNOPSIS
        Ensures the parameter blob is Base64-encoded; encodes if given in plain form.
    .DESCRIPTION
        Tries to Base64-decode the input. If it fails, assumes a plain "#"-separated list
        of "key,value" items, Base64-encodes each value, joins by ";" and Base64-encodes
        the final string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$parameter
    )

    try {
        # If this succeeds, the parameters are already encoded.
        [void](Decode $parameter)
        return $parameter
    }
    catch {
        # Encode from plain input
        $plainParams = $parameter -split '#'
        $ep = ($plainParams | ForEach-Object { Encode $_ }) -join ';'
        $epBytes = [System.Text.Encoding]::UTF8.GetBytes($ep)
        return [Convert]::ToBase64String($epBytes)
    }
}

function Init {
    <#
    .SYNOPSIS
        Initializes scope from an encoded parameter string.
    .OUTPUTS
        PSCustomObject with Parameters (hashtable), DataDir, Version, TimeStamp, TimeStamp2.
    #>
    [CmdletBinding()]
    param (
        [string]$encodedParams = ""
    )

    $encodedParameters = EnsureEncodedParameters -parameter $encodedParams

    $decodedParams = Decode $encodedParameters
    $paramPairs = $decodedParams -split ';'

    $dataDir = $null
    $version = $null
    
    foreach ($pair in $paramPairs) {
        $keyValue = $pair -split ','
        $key = $keyValue[0]
        $value = Decode $keyValue[1]

        switch ($key) {
            'dataDir' { $dataDir = $value }
            'version' { $version = $value }
            'params'  { $parameters = $value }
            default   { Write-Warning "Unknown key: $key" }
        }
    }

    try {
        if (![string]::IsNullOrWhiteSpace($parameters)) {
            # Parse "@{a=b; c=d; }" into hashtable
            $value = $parameters
            $p = @{}
            $value -replace '^\s*@\{|\}\s*$', '' -split ';' |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_) -and $_ -like '*=*') {
                    $key, $val = $_ -split '=', 2  # split only once
                    $p[$key] = $val
                }
            }
        }
        return [PSCustomObject]@{
            Parameters = $p
            DataDir    = $dataDir
            Version    = $version
            TimeStamp  = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
            TimeStamp2 = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        }
    }
    catch {
        Write-Error "Failed to process input: $_"
    }
}

function Notify {
    <#
    .SYNOPSIS
        Emits a standardized item event line to the host (for external log collectors).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$itemName,
        [string]$name,
        [Parameter(Mandatory = $true)]
        [string]$message,
        [string]$category,
        [string]$state,
        [string]$info,
        [int]$resultCode,
        [string]$itemResult
    )

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $itemName
    }

    Write-Host "ItemEvent: Category: $($category) | Name: $($name) | ItemName: $($itemName) | Message: $($message) | State: $($state) | Info: $($info) | ResultCode: $($resultCode) | ItemResult: $($itemResult)"
}

function GetAllPropertyValuesAsString {
    <#
    .SYNOPSIS
        Returns a "Name: Value, Name: Value, ..." string of all public properties of an object.
    #>
    param (
        [Parameter(Mandatory = $true)]
        $object
    )

    $propertyValues = @()
    $object | Get-Member -MemberType Properties | ForEach-Object {
        $propertyName  = $_.Name
        $propertyValue = $object.$propertyName
        $propertyValues += "$($propertyName): $propertyValue"
    }
    return ($propertyValues -join ", ")
}

function Get-LoginventoryConfigPath {
    <#
    .SYNOPSIS
        Builds the path to LOGINventory.config under ProgramData based on major version.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$version
    )
    $MajorVersion = ($version -split '\.')[0]
    $pd = [Environment]::GetFolderPath('CommonApplicationData')  # C:\ProgramData
    # C:\ProgramData\login\loginventory\<MAJOR>.0\LOGINventory.config
    $path = Join-Path $pd "login\loginventory\$MajorVersion.0\LOGINventory.config"
    return $path
}

function Get-LoginventoryConfigSettings {
    <#
    .SYNOPSIS
        Reads selected settings from LOGINventory.config (XML) if present.
    .DESCRIPTION
        Returns a hashtable { name -> value } for the requested setting names.
        Missing or malformed files are tolerated (returns empty result).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string[]]$Names
    )
    $result = @{}
    if (-not (Test-Path $ConfigPath)) { return $result }

    try {
        [xml]$xml = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop
        $settings = $xml.configuration.userSettings.'Login.Ventory.Common.Properties.Settings'.setting
        if (-not $settings) { return $result }

        foreach ($n in $Names) {
            $node = $settings | Where-Object { $_.name -eq $n }
            if ($node) {
                # Value may be a text node or nested; normalize to trimmed string
                $val = [string]$node.value
                if ([string]::IsNullOrWhiteSpace($val)) {
                    $val = ($node.value | Out-String)
                }
                $result[$n] = ($val -as [string]).Trim()
            }
        }
    }
    catch {
        # intentionally silent: a missing/broken file should not be a hard error
    }
    return $result
}

function ConvertTo-Bool {
    <#
    .SYNOPSIS
        Converts common truthy/falsey representations to a Boolean.
    .DESCRIPTION
        - [bool]  : returned as-is
        - null    : false
        - numbers : non-zero => true, zero => false
        - strings : trims & matches (true/t/yes/y/on/1) and (false/f/no/n/off/0), case-insensitive
                    otherwise falls back to [bool]::TryParse; if that fails, returns false
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($Value -is [bool]) { return $Value }
    if ($null -eq $Value)  { return $false }

    # Numeric handling (int, long, double, decimal, etc.)
    if ($Value -is [sbyte] -or $Value -is [byte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or
        $Value -is [decimal]) {
        try { return ([double]$Value) -ne 0 } catch { return $false }
    }

    # String handling
    $s = ([string]$Value).Trim()
    if ($s.Length -eq 0) { return $false }
    switch -regex ($s.ToLowerInvariant()) {
        '^(true|t|yes|y|on|1)$'   { return $true }
        '^(false|f|no|n|off|0)$'  { return $false }
        default {
            $parsed = $false
            if ([bool]::TryParse($s, [ref]$parsed)) { return $parsed }
            return $false
        }
    }
}


function ConvertTo-Xml {
    <#
    .SYNOPSIS
        Serializes the current $lEntities list into LOGINventory LogInfo XML.
    #>
    param (
        [Parameter(Mandatory = $true)]
        $version,
        [Parameter(Mandatory = $false)]
        [bool]$useDataNamespace = $false
    )

    $loginfoNamespaceVersion = ($version -split '\.')[0] + ".0"

    $xmlWriterSettings = New-Object System.Xml.XmlWriterSettings
    $xmlWriterSettings.Indent = $true
    $xmlWriterSettings.OmitXmlDeclaration = $true

    $stringBuilder = New-Object System.Text.StringBuilder
    $xmlWriter = [System.Xml.XmlWriter]::Create($stringBuilder, $xmlWriterSettings)

    $attributePattern = '\{(.+?):(.+?)\}'
    try {
        $xmlWriter.WriteStartDocument()
        $xmlWriter.WriteStartElement('root')

        $namespace = "http://www.loginventory.com/schemas/LOGINventory/data/$loginfoNamespaceVersion"
        if (-not $useDataNamespace) {
            $namespace = $namespace + "/LogInfo"
        }

        foreach ($item in $Script:lEntities) {
            $xmlWriter.WriteStartElement($item.Name, $namespace)

            $previousKeyPrefix = $null
            $keyProperty = $null
            $entitySwitch = $false

            foreach ($entry in $item.Entries) {
                $attributePattern = '\{(.+?)\}'
                $parts = $entry -split '=', 2
                $key = $parts[0].Trim() -replace $attributePattern, ''
                $value = $parts[1].Trim()
                $keyPath = $key.Split('.')
                $matches = [regex]::Matches($parts[0], $attributePattern)

                if ($keyPath.Count -eq 1) {
                    # Simple element
                    $element = $xmlWriter.WriteStartElement($key)
                    foreach ($match in $matches) {
                        $attributes = $match.Groups[1].Value -split ';'
                        foreach ($attribute in $attributes) {
                            $attrParts = $attribute -split ':'
                            if ($attrParts.Count -eq 2) {
                                $xmlWriter.WriteAttributeString($attrParts[0], $attrParts[1])
                            }
                        }
                    }
                    $xmlWriter.WriteString($value)
                    $xmlWriter.WriteEndElement()
                    continue
                }

                # Nested element handling with grouping by first path segment
                $keyPrefix = $keyPath[0]

                if ($keyPrefix -ne $previousKeyPrefix -or ($keyPrefix -eq $previousKeyPrefix -and $keyPath[1] -eq $keyProperty)) {
                    if ($previousKeyPrefix) {
                        $xmlWriter.WriteEndElement()
                    }
                    $entitySwitch = $true
                    $xmlWriter.WriteStartElement($keyPrefix)
                }
                else {
                    $entitySwitch = $false
                }

                if ($entitySwitch) {
                    $keyProperty = $keyPath[1]
                }

                $previousKeyPrefix = $keyPrefix

                if ($keyPath.Count -gt 1) {
                    $element = $xmlWriter.WriteStartElement($keyPath[1])
                    foreach ($match in $matches) {
                        $attributes = $match.Groups[1].Value -split ';'
                        foreach ($attribute in $attributes) {
                            $attrParts = $attribute -split ':'
                            if ($attrParts.Count -eq 2) {
                                $xmlWriter.WriteAttributeString($attrParts[0], $attrParts[1])
                            }
                        }
                    }
                    $xmlWriter.WriteString($value)
                    $xmlWriter.WriteEndElement()
                }
            }

            if ($previousKeyPrefix) {
                $xmlWriter.WriteEndElement()
            }

            $xmlWriter.WriteEndElement()
        }

        $xmlWriter.WriteEndElement()
        $xmlWriter.WriteEndDocument()
        $xmlWriter.Flush()
        $xmlWriter.Close()
    }
    catch {
        Write-Host "$_ - $($_.InvocationInfo.ScriptLineNumber)"
    }
    return $stringBuilder.ToString()
}

function PostProcessXml {
    <#
    .SYNOPSIS
        Wraps produced LogInfo XML into the final Inventory envelope with metadata.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$xml
    )

    $scriptName = $MyInvocation.MyCommand.Name
    $timestamp  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

    $xmlDocument   = New-Object System.Xml.XmlDocument
    $newXmlDocument = New-Object System.Xml.XmlDocument
    $xmlDocument.LoadXml($xml)

    $newRoot = $newXmlDocument.CreateElement("Inventory")
    $newRoot.SetAttribute("xmlns", "http://www.loginventory.com/schemas/LOGINventory/data")
    $newRoot.SetAttribute("Version", $Version)
    $newRoot.SetAttribute("Agent", $scriptName)
    $newRoot.SetAttribute("Timestamp", $timestamp)

    foreach ($node in $xmlDocument.DocumentElement.ChildNodes) {
        $importedNode = $newXmlDocument.ImportNode($node, $true)
        [void]$importedNode.SetAttribute("ClearMissingCustomProperties", "false")
        $newRoot.AppendChild($importedNode) | Out-Null
    }

    $newXmlDocument.AppendChild($newRoot) | Out-Null
    return $newXmlDocument.OuterXml
}

function GetCurrentEntity {
    <#
    .SYNOPSIS
        Returns the most recently created entity object.
    #>
    return $script:lEntities[-1]
}

function NewEntity {
    <#
    .SYNOPSIS
        Starts a new entity (record) with the given name.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$name
    )

    $current = [PSCustomObject]@{
        Name    = $name
        Entries = New-Object System.Collections.ArrayList
    }
    $script:lEntities.Add($current) | Out-Null
}

function AddPropertyValue {
    <#
    .SYNOPSIS
        Adds a "name = value" entry to the current entity.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$name,
        [string]$value = "-"
    )
    $c = GetCurrentEntity
    $c.Entries.Add("$name = $value") | Out-Null
}

function WriteInv {
    <#
    .SYNOPSIS
        Writes the current inventory to disk and clears the in-memory list.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$filePath,

        [Parameter(Mandatory = $true)]
        [string]$version,

        [Parameter(Mandatory = $false)]
        [bool]$useDataNamespace = $false
    )

    $itemXml = ConvertTo-Xml -version $version -useDataNamespace $useDataNamespace
    $mxl = PostProcessXml -Xml $itemXml
    $mxl | Out-File -FilePath $filePath
    $lEntities.Clear() | Out-Null
}

function Merge-ParameterScopes {
    <#
    .SYNOPSIS
        Merges top-level properties of a scope object with its nested "Parameters" hashtable/object.
    .DESCRIPTION
        Top-level values are included except "Parameters"; nested "Parameters" entries overwrite
        top-level keys of the same name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$Scope
    )

    $merged = @{}

    # Copy top-level values from $Scope (excluding "Parameters")
    if ($Scope -is [System.Collections.IDictionary]) {
        foreach ($kv in $Scope.GetEnumerator()) {
            if ($kv.Key -ne 'Parameters') { $merged[$kv.Key] = $kv.Value }
        }
    }
    else {
        foreach ($p in $Scope.PSObject.Properties) {
            if ($p.Name -ne 'Parameters') { $merged[$p.Name] = $p.Value }
        }
    }

    # Merge from nested $Scope.Parameters (overrides)
    $paramsObj = $null
    if ($Scope -is [System.Collections.IDictionary]) {
        if ($Scope.Contains('Parameters')) { $paramsObj = $Scope['Parameters'] }
    }
    else {
        $prop = $Scope.PSObject.Properties['Parameters']
        if ($prop) { $paramsObj = $prop.Value }
    }

    if ($paramsObj) {
        if ($paramsObj -is [System.Collections.IDictionary]) {
            foreach ($kv in $paramsObj.GetEnumerator()) { $merged[$kv.Key] = $kv.Value }
        }
        else {
            foreach ($p in $paramsObj.PSObject.Properties) { $merged[$p.Name] = $p.Value }
        }
    }

    return $merged
}

function Join-Url {
    <#
    .SYNOPSIS
        Joins a base URL and a path with exactly one slash between them.
    #>
    param([string]$Base, [Parameter(Mandatory=$true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Base)) { return $Path.TrimStart('/') }
    return ($Base.TrimEnd('/') + '/' + $Path.TrimStart('/'))
}

function HasValue([object]$v) {
    <#
    .SYNOPSIS
        Returns true if the value is not null or empty/whitespace when stringified.
    #>
    return ($null -ne $v) -and (-not [string]::IsNullOrWhiteSpace([string]$v))
}


function Get-EffectiveValue {
    <#
    .SYNOPSIS
        Returns a value from Primary or Fallback by name, with optional default and type coercion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$Primary,
        [Parameter(Mandatory=$true)][hashtable]$Fallback,
        [Parameter(Mandatory=$true)][string]$Name,
        [object]$Default = $null,
        [ValidateSet('string','int','bool','double','datetime','object')][string]$As = 'object'
    )
    $val = $null
    if ($Primary.ContainsKey($Name) -and (HasValue $Primary[$Name])) { $val = $Primary[$Name] }
    elseif ($Fallback.ContainsKey($Name) -and (HasValue $Fallback[$Name])) { $val = $Fallback[$Name] }
    elseif ($PSBoundParameters.ContainsKey('Default')) { $val = $Default }

    if ($null -eq $val) { return $null }

    switch ($As) {
        'string'   { return [string]$val }
        'int'      { return [int]$val }
        'bool'     { return (ConvertTo-Bool $val) }
        'double'   { return [double]$val }
        'datetime' { return [datetime]$val }
        default    { return $val }
    }
}

function Resolve-CommonEffectiveConfig {
    <#
    .SYNOPSIS
        Resolves effective common settings by merging user parameters with LOGINventory.config.
    .DESCRIPTION
        Precedence: explicit Parameters > file config (LOGINventory.config).
        Returns a PSCustomObject with Version, ConfigPath, LiInstallPath, DebugFile, ProxyConfig, TimeStamp, TimeStamp2, DataDir.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$Parameters
    )

    # --- Version & config path ------------------------------------------------
    $version = $Parameters['version']
    if (-not $version) { throw "No version parameter set!" }
    $cfgPath = Get-LoginventoryConfigPath -Version $version

    # --- Keys handled by "common" --------------------------------------------
    $keys = @(
        'WebProxyActive','WebProxyUrl','WebProxyUserName','WebProxyPassword','WebProxyUseDefaultCredentials',
        'LiInstallPath','DebugFile','TimeStamp','TimeStamp2','DataDir'
    )
    $fileCfg = @{}
    if (HasValue $cfgPath) { $fileCfg = Get-LoginventoryConfigSettings -ConfigPath $cfgPath -Names $keys }

    # --- Effective values: PARAM > FILE --------------------------------------
    $eff_WebProxyActive   = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'WebProxyActive'   -As bool
    $eff_UseDefaultCredentials = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'WebProxyUseDefaultCredentials' -Default $null -As bool
    $eff_WebProxyUrl      = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'WebProxyUrl'      -As string
    $eff_WebProxyUserName = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'WebProxyUserName' -As string
    $eff_WebProxyPassword = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'WebProxyPassword' -As string
    $installPath          = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'LiInstallPath'    -As string
    $debugFile            = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'DebugFile'        -As string
    $timeStamp            = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'TimeStamp'        -As string
    $timeStamp2           = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'TimeStamp2'       -As string
    $dataDir              = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'DataDir'          -As string

    # --- ProxyConfig (always present; never $null) ----------------------------
    $proxyConfig = @{
        Active                = (ConvertTo-Bool $eff_WebProxyActive)
        Url                   = $null
        Username              = $null
        Password              = $null
        UseDefaultCredentials = $false
    }
    if ($proxyConfig.Active) {
        if (HasValue $eff_WebProxyUrl)      { $proxyConfig.Url      = [string]$eff_WebProxyUrl }
        if (HasValue $eff_WebProxyUserName) {
            $proxyConfig.Username = [string]$eff_WebProxyUserName
            if (HasValue $eff_WebProxyPassword) { $proxyConfig.Password = [string]$eff_WebProxyPassword }
        }
        else {
            if (HasValue $eff_UseDefaultCredentials) {
                $proxyConfig.UseDefaultCredentials = $eff_UseDefaultCredentials
            }
            else {
                # Default to using the current user's credentials when no explicit user is provided.
                $proxyConfig.UseDefaultCredentials = $true
            }
        }
    }

    # --- Result ---------------------------------------------------------------
    return [pscustomobject]@{
        Version       = $version
        ConfigPath    = $cfgPath
        LiInstallPath = $installPath
        DebugFile     = $debugFile
        ProxyConfig   = $proxyConfig
        TimeStamp     = $timeStamp
        TimeStamp2    = $timeStamp2
        DataDir       = $dataDir
    }
}

function New-CommonContext {
    <#
    .SYNOPSIS
        Builds a common runtime context from encoded parameters and LOGINventory.config.
    .OUTPUTS
        PSCustomObject with effective settings and merged user parameters.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Parameters,
        [string]$StartLabel = 'RUN'
    )

    $scope = Init -encodedParams $Parameters

    # Build merged param view (top-level + nested Parameters)
    $allParams = Merge-ParameterScopes -Scope $scope

    $eff = Resolve-CommonEffectiveConfig -Parameters $allParams

    $ctx = [pscustomobject]@{
        # Core
        Version        = $eff.Version
        ConfigPath     = $eff.ConfigPath
        LiInstallPath  = $eff.LiInstallPath
        ProxyConfig    = $eff.ProxyConfig
        TimeStamp      = $eff.TimeStamp
        TimeStamp2     = $eff.TimeStamp2
        DataDir        = $eff.DataDir
        # Debug
        DebugFile      = $eff.DebugFile
        # Parameter
        UserParameters = $allParams
    }

    if (HasValue $ctx.DebugFile) {
        $dir = Split-Path -Path $ctx.DebugFile -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        "===== $StartLabel Start {0:yyyy-MM-ddTHH:mm:ss.fffZ} =====" -f (Get-Date).ToUniversalTime() | Out-File -FilePath $ctx.DebugFile -Append -Encoding UTF8

        $proxyUrl = if ($ctx.ProxyConfig.Url) { [string]$ctx.ProxyConfig.Url } else { '<none>' }
        Write-CommonDebug -Context $ctx -Message ("Common Effective: Version={0}; CfgPath={1}; LiInstallPath={2}; ProxyUrl={3}" -f $ctx.Version,$ctx.ConfigPath,$ctx.LiInstallPath,$proxyUrl)
    }

    return $ctx
}

function New-SafeFileName {
    <#
    .SYNOPSIS
        Produces a Windows-safe file name (no path), replacing invalid characters and
        shortening overly long names with a short hash suffix.
    .PARAMETER Name
        The raw name to sanitize (e.g., software name, version, device id).
    .PARAMETER MaxLength
        Max length of the resulting file name (without path). Default: 120 chars.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$MaxLength = 120
    )

    # Replace invalid filename chars by underscore
    $safe = $Name
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe -replace [regex]::Escape([string]$ch), '_'
    }
    # Normalize whitespace and underscores
    $safe = $safe -replace '\s+', ' '
    $safe = $safe.Trim()
    $safe = $safe -replace '\s', '_'               # spaces -> underscore
    $safe = $safe -replace '_{2,}', '_'            # collapse runs of underscores
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'item' }

    # Enforce length with short hash suffix for uniqueness if needed
    if ($safe.Length -gt $MaxLength) {
        try {
            $sha1 = New-Object System.Security.Cryptography.SHA1Managed
            $bytes = [Text.Encoding]::UTF8.GetBytes($Name)
            $hash  = ($sha1.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
            $suffix = '_' + $hash.Substring(0,8)
        } catch { $suffix = '_trunc' }

        $keep = [Math]::Max(1, $MaxLength - $suffix.Length)
        $safe = $safe.Substring(0, $keep) + $suffix
    }
    return $safe
}

function Write-CommonDebug {
    <#
    .SYNOPSIS
        Appends a UTC timestamped line to the DebugFile contained in the given context.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][string]$Message
    )
    if ($Context.DebugFile) {
        "{0:O} | {1}" -f (Get-Date).ToUniversalTime(), $Message | Out-File -FilePath $Context.DebugFile -Append -Encoding UTF8
    }
}

function Initialize-LiDrive {
    <#
    .SYNOPSIS
        Ensures the LOGINventory PSDrive (LI:) is available.
    .PARAMETER installPath
        Optional install path passed to LOGINventory snap-ins/app-domain.
    #>
    [CmdletBinding()]
    param([pscustomobject]$context)

    # Determine LI install path; default to PowerShell home folder if not set
    $installPath = $context.LiInstallPath
    if ([string]::IsNullOrWhiteSpace($installPath)) {
        $installPath = Split-Path -Path $PSHome
    } else {
        $installPath = $installPath.Trim()
    }
    if (-not (Get-PSDrive -Name Li -ErrorAction SilentlyContinue)) {
        Add-PSSnapin loginventory
        Add-PSSnapin loginventorycmdlets
        # Set culture to English (avoid localized field names in LI data)
        [System.Threading.Thread]::CurrentThread.CurrentUICulture = "en-US"
        [System.AppDomain]::CurrentDomain.SetPrincipalPolicy([System.Security.Principal.PrincipalPolicy]::WindowsPrincipal)
        [System.AppDomain]::CurrentDomain.SetData("APPBASE", $installPath)
        New-PSDrive -Scope global -Name LI -PSProvider LOGINventory -Root ""
    }
}