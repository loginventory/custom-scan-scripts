<#
    File:        CyberInsight-common.ps1
    Purpose:     Build a CyberInsight runtime context from common settings, resolve
                 effective CI configuration, and provide authenticated API helpers.

    Contents:
      - Resolve-CI-EffConfig : Merge CI-specific parameters with file config (LOGINventory.config)
      - New-CIContext        : Build a CI context (wraps Common + CI settings; token cache)
      - Get-CIAccessToken    : Exchange API key for a bearer token (cached with expiry)
      - Invoke-CIApi         : Call CI API with auto token attach and one-time auth refresh
      - Send-CIThreatFinderData : POST a ThreatFinder payload with optional gzip request compression,
                                  size checks against the documented gateway limits and an uncompressed fallback
      - Get-CISubmitErrorMessage : Human-readable error text for a failed ThreatFinder submission

    Key features:
      * Parameter precedence: explicit parameters > LOGINventory.config
      * Builds ApiUrl as <BaseUrl>/api/v1
      * Proxy support is inherited from Common context
      * Token caching with drift (refresh 60s before expiry)
      * One-time retry on 401/403/498/499 with token refresh
      * Gzip request compression (Content-Encoding: gzip) for large ThreatFinder payloads,
        controlled by CyberInsightCompression = auto | always | never (see gzip docs:
        https://documentation-433337190849.europe-west3.run.app/gzip-compression/)
      * Debug logging via Write-CommonDebug (if DebugFile is configured)

    Requirements:
      - This file expects the following includes to be loaded before use:
          include\common.ps1     (New-CommonContext, helpers, proxy/config resolution)
          include\WebRequest.ps1 (Invoke-LoginWebRequest, URL normalization)
      - Windows PowerShell 5.1
#>

. (Join-Path -Path $PSScriptRoot -ChildPath "..\include\common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "..\include\WebRequest.ps1")

function Resolve-CI-EffConfig {
    <#
    .SYNOPSIS
        Resolves effective CyberInsight settings (parameters override file config).
    .PARAMETER Parameters
        Hashtable with user-provided parameters (typically Common.UserParameters).
    .PARAMETER Common
        The Common context object returned by New-CommonContext.
    .OUTPUTS
        PSCustomObject with BaseUrl, ApiKey, CompanyName, KeyProperty, Criticality, ExportQuery, SyncQuery,
        Language, Compression (auto | always | never), CompressionMinSizeKB.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$Parameters,
        [Parameter(Mandatory=$true)]$Common
    )

    # CI-specific keys to read from LOGINventory.config if present
    $keys = @(
        'CyberInsightEndpoint','CyberInsightApiKey','CyberInsightApiLanguage',
        'CyberInsightCompanyName','CyberInsightKeyProperty','CyberInsightCriticality',
        'CyberInsightExportQuery', 'CyberInsightSyncQuery',
        'CyberInsightCompression', 'CyberInsightCompressionMinSizeKB'
    )

    $fileCfg = @{}
    if (HasValue $Common.ConfigPath) {
        $fileCfg = Get-LoginventoryConfigSettings -ConfigPath $Common.ConfigPath -Names $keys
    }

    $endpoint     = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'CyberInsightEndpoint'    -As string -Default 'https://ci-gateway-5j2lrwe9.nw.gateway.dev'
    $apiKey       = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'CyberInsightApiKey'      -As string
    $company      = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'CyberInsightCompanyName' -As string
    $keyProperty  = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'CyberInsightKeyProperty' -As string -Default 'Name'
    $criticality  = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'CyberInsightCriticality' -As string -Default 'high|medium'
    $exportQuery  = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'CyberInsightExportQuery' -As string -Default 'Vulnerability Assessment\Vulnerability Export'
    $syncQuery  = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'CyberInsightSyncQuery' -As string -Default 'Vulnerability Assessment\All Vulnerabilities per Software Package'
   $language     = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'CyberInsightApiLanguage' -Default 'en' -As string

    # --- Gzip request compression for ThreatFinder uploads --------------------
    #   CyberInsightCompression          : auto (default) = gzip when the JSON payload is >= CyberInsightCompressionMinSizeKB
    #                                      always         = gzip every submission
    #                                      never          = plain JSON (previous behaviour)
    #   CyberInsightCompressionMinSizeKB : threshold for "auto" in KB (default 100 KB, as recommended by CyberInsight)
    $compressionRaw = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'CyberInsightCompression' -As string -Default 'auto'
    $compression    = ConvertTo-CICompressionMode -Value $compressionRaw
    if (([string]$compressionRaw).Trim().ToLowerInvariant() -notin 'auto','always','never') {
        Write-CommonDebug -Context $Common -Message ("CyberInsightCompression='{0}' interpreted as '{1}' (valid: auto | always | never)" -f $compressionRaw, $compression)
    }
    $minSizeKbRaw   = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'CyberInsightCompressionMinSizeKB' -As string -Default '100'
    $minSizeKb      = 100
    $parsedKb       = 0
    if ([int]::TryParse(([string]$minSizeKbRaw).Trim(), [ref]$parsedKb) -and $parsedKb -ge 0) { $minSizeKb = $parsedKb }
    else { Write-CommonDebug -Context $Common -Message ("CyberInsightCompressionMinSizeKB='{0}' is not a non-negative integer; using default {1} KB" -f $minSizeKbRaw, $minSizeKb) }

    [pscustomobject]@{
        BaseUrl              = $endpoint
        ApiKey               = $apiKey
        CompanyName          = $company
        KeyProperty          = $keyProperty
        Criticality          = $criticality
        ExportQuery          = $exportQuery
        SyncQuery            = $syncQuery
        Language             = $language
        Compression          = $compression
        CompressionMinSizeKB = $minSizeKb
    }
}

function ConvertTo-CICompressionMode {
    <#
    .SYNOPSIS
        Normalizes the CyberInsightCompression setting to 'auto' | 'always' | 'never'.
    .DESCRIPTION
        Accepts common synonyms (on/true/yes/1/gzip/force -> always; off/false/no/0/none -> never).
        Empty or unknown values fall back to 'auto'.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    $s = if ($null -ne $Value) { ([string]$Value).Trim().ToLowerInvariant() } else { '' }
    switch -regex ($s) {
        '^(auto|default)?$'                    { return 'auto' }
        '^(always|on|true|yes|y|1|gzip|force)$' { return 'always' }
        '^(never|off|false|no|n|0|none)$'       { return 'never' }
        default                                 { return 'auto' }
    }
}

function New-CIContext {
    <#
    .SYNOPSIS
        Builds the CyberInsight context object based on Common context.
    .PARAMETER Common
        The Common context object (from New-CommonContext).
    .PARAMETER StartLabel
        Optional label written at the start of the debug log section.
    .OUTPUTS
        PSCustomObject holding Common, CI details, and a token cache.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Common,
        [string]$StartLabel = 'RUN'
    )

    $ci = Resolve-CI-EffConfig -Parameters $Common.UserParameters -Common $Common

    $ctx = [pscustomobject]@{
        Common        = $Common

        # ---- Domain-specific (CI) ----
        ApiUrl        = if (HasValue $ci.BaseUrl) { Join-Url -Base $ci.BaseUrl -Path 'api/v1' } else { $null }
        ApiKey        = $ci.ApiKey
        CompanyName   = $ci.CompanyName
        KeyProperty   = $ci.KeyProperty
        Criticality   = $ci.Criticality
        ExportQuery   = $ci.ExportQuery
        SyncQuery     = $ci.SyncQuery
        Language      = $ci.Language

        # ---- Gzip request compression (ThreatFinder upload) ----
        Compression         = $ci.Compression                       # auto | always | never
        CompressionMinBytes = [long]$ci.CompressionMinSizeKB * 1024  # threshold for "auto"

        # ---- Token cache ----
        AccessToken   = $null
        TokenType     = 'Bearer'
        TokenExpiry   = [DateTime]::MinValue
    }

    if (HasValue $ctx.Common.DebugFile) {
        $proxyUrl = if ($ctx.Common.ProxyConfig.Url) { [string]$ctx.Common.ProxyConfig.Url } else { '<none>' }
        Write-CommonDebug -Context $ctx.Common -Message ("CI Effective: ApiUrl={0}; ProxyUrl={1}; Version={2}; CfgPath={3}" -f $ctx.ApiUrl,$proxyUrl,$ctx.Common.Version,$ctx.Common.ConfigPath)
        Write-CommonDebug -Context $ctx.Common -Message ("CI Params: Company={0}; KeyProp={1}; Language={2}; Criticality={3}" -f $ctx.CompanyName,$ctx.KeyProperty,$ctx.Language,$ctx.Criticality)
        Write-CommonDebug -Context $ctx.Common -Message ("CI Compression: Mode={0}; MinSizeKB={1}" -f $ctx.Compression,$ci.CompressionMinSizeKB)
    }

    return $ctx
}

function Get-CIAccessToken {
    <#
    .SYNOPSIS
        Retrieves (and caches) a bearer token using the configured API key.
    .PARAMETER Context
        CI context built by New-CIContext.
    .OUTPUTS
        String bearer token.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Context)

    # Return cached token if still valid
    if ($Context.AccessToken -and (Get-Date) -lt $Context.TokenExpiry) { return $Context.AccessToken }

    if (-not (HasValue $Context.ApiUrl)) { throw "API base URL (ApiUrl) is not set." }
    if (-not (HasValue $Context.ApiKey)) { throw "API key is not set." }

    # Token endpoint: /auth/api_keys/token
    $tokenUri = Join-Url -Base $Context.ApiUrl -Path 'auth/api_keys/token'

    $headers = @{
        'Accept-Language' = $Context.Language
        'Content-Type'    = 'application/json'
    }
    $bodyObj = @{ api_key = $Context.ApiKey }
    $body    = $bodyObj | ConvertTo-Json -Depth 5

    Write-CommonDebug -Context $Context.Common -Message ("Fetching bearer via API key at {0}" -f $tokenUri)
    $resp = Invoke-LoginWebRequest -Method POST -Uri $tokenUri -Headers $headers -Body $body -ProxyConfig $Context.Common.ProxyConfig -DebugFile $Context.Common.DebugFile
    if (-not $resp.IsSuccess) { throw "Token request failed: HTTP $($resp.StatusCode) $($resp.StatusDescription)" }

    $tok = $resp.Body | ConvertFrom-Json
    if (-not $tok.access_token) { throw "No access_token in token response." }

    $Context.AccessToken = [string]$tok.access_token
    $Context.TokenType   = if ($tok.token_type) { [string]$tok.token_type } else { "Bearer" }

    # Set expiry with 60s safety margin; ensure minimum TTL 60s
    $ttl = 300
    if ($tok.expires_in -and ($tok.expires_in -as [int])) { $ttl = [Math]::Max(60, ([int]$tok.expires_in) - 60) }
    $Context.TokenExpiry = (Get-Date).AddSeconds($ttl)

    Write-CommonDebug -Context $Context.Common -Message ("Token acquired (type={0}), exp in ~{1}s" -f $Context.TokenType, $ttl)
    return $Context.AccessToken
}

function Invoke-CIApi {
    <#
    .SYNOPSIS
        Invokes a CyberInsight API endpoint with auth and optional body/headers.
    .PARAMETER Context
        CI context built by New-CIContext.
    .PARAMETER Method
        HTTP method (GET, POST, PUT, PATCH, DELETE).
    .PARAMETER Path
        Relative API path (appended to Context.ApiUrl).
    .PARAMETER Headers
        Optional additional headers (hashtable). "Accept-Language" is added if missing.
    .PARAMETER Body
        Optional request body: [string] (e.g., JSON) or [byte[]] (e.g., gzip-compressed JSON;
        add 'Content-Encoding' = 'gzip' to Headers in that case).
    .PARAMETER GzipBody
        Compress the body with gzip before sending (adds "Content-Encoding: gzip").
    .OUTPUTS
        The structured response object returned by Invoke-LoginWebRequest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [hashtable]$Headers,
        [object]$Body,
        [switch]$GzipBody
    )

    if (-not (HasValue $Context.ApiUrl)) { throw "API base URL (ApiUrl) is not set." }
    $uri = Join-Url -Base $Context.ApiUrl -Path $Path

    # Compose headers
    $hdr = @{}
    if ($Headers) { $Headers.GetEnumerator() | ForEach-Object { $hdr[$_.Key] = $_.Value } }

    # Propagate language (useful outside token call as well)
    if (-not $hdr.ContainsKey('Accept-Language')) { $hdr['Accept-Language'] = $Context.Language }

    # Attach bearer token
    $token = Get-CIAccessToken -Context $Context
    $hdr['Authorization'] = "{0} {1}" -f $Context.TokenType, $token

    $resp = Invoke-LoginWebRequest -Method $Method -Uri $uri -Headers $hdr -Body $Body -GzipBody:$GzipBody -ProxyConfig $Context.Common.ProxyConfig -DebugFile $Context.Common.DebugFile

    # One-time refresh on auth failure
    if (-not $resp.IsSuccess -and ($resp.StatusCode -in 401,403,498,499)) {
        Write-CommonDebug -Context $Context.Common -Message ("Auth failed (HTTP {0}), refreshing token and retrying once..." -f $resp.StatusCode)
        $Context.AccessToken = $null
        $Context.TokenExpiry = [DateTime]::MinValue
        $token = Get-CIAccessToken -Context $Context
        $hdr['Authorization'] = "{0} {1}" -f $Context.TokenType, $token
        $resp = Invoke-LoginWebRequest -Method $Method -Uri $uri -Headers $hdr -Body $Body -GzipBody:$GzipBody -ProxyConfig $Context.Common.ProxyConfig -DebugFile $Context.Common.DebugFile
    }
    elseif (-not $resp.IsSuccess -and ($resp.StatusCode -in 422))
    {
        $msg = Get-ApiValidationErrorMessage -ErrorPayload $resp.Body
        Write-CommonDebug -Context $Context.Common -Message $msg
    }

    return $resp
}

function Get-ApiValidationErrorMessage {
    param (
        [Parameter(Mandatory)]
        [object]$ErrorPayload
    )

    try {
        # Convert JSON string to object if needed
        if ($ErrorPayload -is [string]) {
            $obj = $ErrorPayload | ConvertFrom-Json -ErrorAction Stop
        }
        else {
            $obj = $ErrorPayload
        }

        if (-not $obj.detail) {
            return "API error: Unknown validation error format."
        }

        $messages = foreach ($err in $obj.detail) {

            # Build location string (e.g. body.items[0].name)
            $location = if ($err.loc) {
                ($err.loc | ForEach-Object {
                    # PS5 deserializes JSON numbers as [int], PS7 as [long]
                    if ($_ -is [int] -or $_ -is [long]) { "[$_]" } else { ".$_" }
                }) -join ""
            }
            else {
                ""
            }

            $location = $location.TrimStart('.')

            # Compose readable message
            if ($location) {
                "$($location): $($err.msg)"
            }
            else {
                $err.msg
            }
        }

        return $messages -join "; "
    }
    catch {
        # Absolute fallback – never throw from an error formatter
        return "API error: Failed to parse validation error response. $($_.Exception.Message)"
    }
}

function Format-CIBytes {
    <#
    .SYNOPSIS
        Formats a byte count as a short, culture-invariant string (e.g. "12.3 MB", "512 KB", "80 B").
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][long]$Bytes)

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1MB) { return [string]::Format($inv, '{0:0.#} MB', ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return [string]::Format($inv, '{0:0.#} KB', ($Bytes / 1KB)) }
    return [string]::Format($inv, '{0} B', $Bytes)
}

function Send-CIThreatFinderData {
    <#
    .SYNOPSIS
        POSTs a ThreatFinder payload (JSON string) to /threat-finder/submit, applying gzip request
        compression according to Context.Compression (auto | always | never).
    .DESCRIPTION
        Compression modes (setting CyberInsightCompression):
          auto   : gzip when the UTF-8 payload is >= Context.CompressionMinBytes (CyberInsightCompressionMinSizeKB, default 100 KB)
          always : gzip every submission
          never  : plain JSON (behaviour before gzip support)
        Gzip requests are sent with "Content-Encoding: gzip" and "Content-Type: application/json" exactly as
        documented at https://documentation-433337190849.europe-west3.run.app/gzip-compression/.
        Documented gateway limits: 32 MB per request body (compressed or plain), 150 MB decompressed.
        The payload is checked against these limits before sending; violations are returned as Warnings
        (the request is still sent - the gateway remains the authority).
        Fallback: in "auto" mode, if the gzip request itself is rejected with HTTP 400 or 415 (e.g. a proxy
        tampering with Content-Encoding) and the plain payload still fits into the request limit, the
        submission is retried once uncompressed. "always" never falls back.
    .PARAMETER Context
        CI context built by New-CIContext.
    .PARAMETER JsonBody
        The complete JSON document to submit (UTF-8 encoded on the wire).
    .PARAMETER Path
        Relative API path (default: threat-finder/submit).
    .OUTPUTS
        PSCustomObject: Response (Invoke-LoginWebRequest result), CompressionMode, CompressionUsed, FallbackUsed,
        FallbackStatusCode, PayloadBytes (uncompressed UTF-8 size), SentBytes (bytes on the wire), CompressionMs,
        Warnings (string[]), Summary (short text for logs/notifications).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$JsonBody,
        [string]$Path = 'threat-finder/submit'
    )

    # Documented gateway limits (https://documentation-433337190849.europe-west3.run.app/gzip-compression/)
    $maxRequestBytes      = 32MB    # request body on the wire (compressed or plain)
    $maxDecompressedBytes = 150MB   # decompressed payload

    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($JsonBody)
    $payloadLen   = [long]$payloadBytes.Length

    $mode = 'auto'
    if (HasValue $Context.Compression) { $mode = ([string]$Context.Compression).Trim().ToLowerInvariant() }
    $minBytes = [long]100KB
    if ($null -ne $Context.CompressionMinBytes) { $minBytes = [long]$Context.CompressionMinBytes }

    $useGzip = $false
    switch ($mode) {
        'always' { $useGzip = $true }
        'never'  { $useGzip = $false }
        default  { $useGzip = ($payloadLen -ge $minBytes) }
    }

    $body    = $null
    $headers = @{}
    $sentLen = $payloadLen
    $gzipMs  = [long]0
    if ($useGzip) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $body = ConvertTo-GzipBytes -InputObject $payloadBytes
        $sw.Stop()
        $gzipMs  = $sw.ElapsedMilliseconds
        $sentLen = [long]$body.Length
        $headers['Content-Encoding'] = 'gzip'
        $headers['Content-Type']     = 'application/json'   # exactly as documented for gzip requests
    }
    else {
        $body = $JsonBody
    }

    # Pre-flight checks against the documented limits (informational; the request is still sent)
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($sentLen -gt $maxRequestBytes) {
        if ($useGzip) {
            $warnings.Add(("The gzip-compressed payload ({0}) exceeds the documented request limit of {1}; the API will most likely respond with HTTP 413. The inventory is too large for a single submission." -f (Format-CIBytes $sentLen), (Format-CIBytes $maxRequestBytes)))
        }
        else {
            $warnings.Add(("The uncompressed payload ({0}) exceeds the documented request limit of {1}; the API will most likely respond with HTTP 413. Set CyberInsightCompression=auto (default) or always to enable gzip compression." -f (Format-CIBytes $sentLen), (Format-CIBytes $maxRequestBytes)))
        }
    }
    if ($useGzip -and $payloadLen -gt $maxDecompressedBytes) {
        $warnings.Add(("The uncompressed payload ({0}) exceeds the documented decompressed-size limit of {1}; the API will most likely respond with HTTP 413." -f (Format-CIBytes $payloadLen), (Format-CIBytes $maxDecompressedBytes)))
    }

    Write-CommonDebug -Context $Context.Common -Message ("ThreatFinder submit: mode={0}; gzip={1}; payload={2} ({3} bytes); sent={4} ({5} bytes); gzipTime={6} ms" -f $mode, $useGzip, (Format-CIBytes $payloadLen), $payloadLen, (Format-CIBytes $sentLen), $sentLen, $gzipMs)
    foreach ($w in $warnings) { Write-CommonDebug -Context $Context.Common -Message ("WARNING: {0}" -f $w) }

    $resp = Invoke-CIApi -Context $Context -Method POST -Path $Path -Headers $headers -Body $body

    # Fallback: "auto" mode only - if the gzip request itself was rejected and the plain payload fits, retry once uncompressed.
    # Triggers on 400/415 (gateway: invalid/unsupported encoding) and on a 422 whose detail is a JSON decode error
    # (a proxy that strips Content-Encoding but forwards the gzip bytes makes the gateway parse binary data as JSON).
    $fallbackUsed   = $false
    $fallbackStatus = 0
    $gzipRejected = $false
    if ($useGzip -and $mode -ne 'always' -and -not $resp.IsSuccess) {
        if ($resp.StatusCode -in 400,415) { $gzipRejected = $true }
        elseif ($resp.StatusCode -eq 422 -and $resp.Body -and ([string]$resp.Body -match '(?i)json[_ ]?(invalid|decode)|invalid json|expecting value')) { $gzipRejected = $true }
    }
    if ($gzipRejected) {
        if ($payloadLen -le $maxRequestBytes) {
            $fallbackStatus = [int]$resp.StatusCode
            Write-CommonDebug -Context $Context.Common -Message ("gzip submission rejected with HTTP {0} {1}; retrying once uncompressed ({2})" -f $resp.StatusCode, $resp.StatusDescription, (Format-CIBytes $payloadLen))
            $fallbackUsed = $true
            $useGzip      = $false
            $sentLen      = $payloadLen
            $resp = Invoke-CIApi -Context $Context -Method POST -Path $Path -Body $JsonBody
        }
        else {
            Write-CommonDebug -Context $Context.Common -Message ("gzip submission rejected with HTTP {0}; uncompressed fallback skipped because the plain payload ({1}) exceeds the request limit of {2}" -f $resp.StatusCode, (Format-CIBytes $payloadLen), (Format-CIBytes $maxRequestBytes))
        }
    }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($useGzip) {
        $ratio   = if ($sentLen -gt 0) { ($payloadLen / $sentLen).ToString('0.0', $inv) } else { '-' }
        $summary = "payload {0}, sent {1} gzip-compressed (ratio {2}:1, {3} ms)" -f (Format-CIBytes $payloadLen), (Format-CIBytes $sentLen), $ratio, $gzipMs
    }
    elseif ($fallbackUsed) {
        $summary = "payload {0}, sent uncompressed after gzip fallback (HTTP {1})" -f (Format-CIBytes $payloadLen), $fallbackStatus
    }
    else {
        $summary = "payload {0}, sent uncompressed" -f (Format-CIBytes $payloadLen)
    }

    return [pscustomobject]@{
        Response           = $resp
        CompressionMode    = $mode
        CompressionUsed    = $useGzip
        FallbackUsed       = $fallbackUsed
        FallbackStatusCode = $fallbackStatus
        PayloadBytes       = $payloadLen
        SentBytes          = $sentLen
        CompressionMs      = $gzipMs
        Warnings           = @($warnings)
        Summary            = $summary
    }
}

function Get-CISubmitErrorMessage {
    <#
    .SYNOPSIS
        Builds a human-readable error message for a failed Send-CIThreatFinderData result,
        including the documented gateway limits and hints for gzip-related failures.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$SubmitResult)

    $resp = $SubmitResult.Response
    $code = 0
    try { $code = [int]$resp.StatusCode } catch { $code = 0 }
    $desc = ([string]$resp.StatusDescription).Trim()
    $mode = [string]$SubmitResult.CompressionMode

    # Prefer the API's "detail" text when the body is JSON ({"detail": "..."}), else a trimmed, single-line body preview
    # (Notify() events must stay on one line).
    $detail = ''
    if ($resp.Body) {
        $detail = [string]$resp.Body
        try {
            $obj = $detail | ConvertFrom-Json -ErrorAction Stop
            if ($obj -and $obj.PSObject.Properties['detail'] -and ($obj.detail -is [string])) { $detail = [string]$obj.detail }
        } catch { }
        $detail = ($detail -replace '\s+', ' ').Trim().TrimEnd('.')
        if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) + '...' }
    }
    $head = "HTTP {0} {1}" -f $code, $desc
    if ($detail) { $head += ": " + $detail }

    $sizes = if ($SubmitResult.CompressionUsed) {
        "sent {0} gzip-compressed, {1} uncompressed" -f (Format-CIBytes $SubmitResult.SentBytes), (Format-CIBytes $SubmitResult.PayloadBytes)
    } else {
        "sent {0} uncompressed" -f (Format-CIBytes $SubmitResult.SentBytes)
    }
    if ($SubmitResult.FallbackUsed) {
        $sizes += "; the gzip-compressed request was rejected first with HTTP {0}" -f $SubmitResult.FallbackStatusCode
    }

    # Hint on how to get compression, depending on why the request was uncompressed
    $enableHint = switch ($mode) {
        'never' { " Set CyberInsightCompression=auto (default) or always to enable gzip compression." }
        'auto'  { if ($SubmitResult.FallbackUsed) { '' } else { " The payload was below CyberInsightCompressionMinSizeKB; lower the threshold or set CyberInsightCompression=always." } }
        default { '' }
    }

    switch ($code) {
        413 {
            $hint = if ($SubmitResult.CompressionUsed) { " The inventory is too large for a single submission even with gzip compression." } else { $enableHint }
            return ("{0}. Documented limits: 32 MB request body, 150 MB decompressed; {1}.{2}" -f $head, $sizes, $hint)
        }
        408 {
            return ("{0}. The upload ({1}) was too slow for the gateway (5 s per chunk / 300 s total); check bandwidth and proxies.{2}" -f $head, $sizes, $enableHint)
        }
        { $_ -in 400,415,422 } {
            $hint = if ($SubmitResult.CompressionUsed) {
                " The gzip-compressed request was rejected - check whether a proxy/firewall alters the request (Content-Encoding) or set CyberInsightCompression=never."
            } else { '' }
            return ("{0} ({1}).{2}" -f $head, $sizes, $hint)
        }
        0 {
            $hint = if ($SubmitResult.CompressionUsed) { " The gzip-compressed upload failed at transport level; if this started with compression enabled, try CyberInsightCompression=never." } else { '' }
            return ("{0} ({1}).{2}" -f $head, $sizes, $hint)
        }
        default {
            return ("{0} ({1})" -f $head, $sizes)
        }
    }
}
