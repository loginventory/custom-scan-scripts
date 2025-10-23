<#
    File:        CyberInsight-common.ps1
    Purpose:     Build a CyberInsight runtime context from common settings, resolve
                 effective CI configuration, and provide authenticated API helpers.

    Contents:
      - Resolve-CI-EffConfig : Merge CI-specific parameters with file config (LOGINventory.config)
      - New-CIContext        : Build a CI context (wraps Common + CI settings; token cache)
      - Get-CIAccessToken    : Exchange API key for a bearer token (cached with expiry)
      - Invoke-CIApi         : Call CI API with auto token attach and one-time auth refresh

    Key features:
      * Parameter precedence: explicit parameters > LOGINventory.config
      * Builds ApiUrl as <BaseUrl>/api/v1
      * Proxy support is inherited from Common context
      * Token caching with drift (refresh 60s before expiry)
      * One-time retry on 401/403/498/499 with token refresh
      * Debug logging via Write-CommonDebug (if DebugFile is configured)

    Requirements:
      - This file expects the following includes to be loaded before use:
          include\common.ps1     (New-CommonContext, helpers, proxy/config resolution)
          include\WebRequest.ps1 (Invoke-LoginWebRequest, URL normalization)
      - Windows PowerShell 5.1 or PowerShell 7+

    Last Updated: 2025-09-26
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
        PSCustomObject with BaseUrl, ApiKey, CompanyName, KeyProperty, Criticality,
        ExportQuery, Language.
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
        'CyberInsightExportQuery', 'CyberInsightSyncQuery'
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
    $syncQuery  = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'CyberInsightSyncQuery' -As string -Default 'Vulnerability Assessment\Software Vulnerabilities'
   $language     = Get-EffectiveValue -Primary $Parameters -Fallback $fileCfg -Name 'CyberInsightApiLanguage' -Default 'en' -As string

    [pscustomobject]@{
        BaseUrl     = $endpoint
        ApiKey      = $apiKey
        CompanyName = $company
        KeyProperty = $keyProperty
        Criticality = $criticality
        ExportQuery = $exportQuery
        SyncQuery   = $syncQuery
        Language    = $language
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

        # ---- Token cache ----
        AccessToken   = $null
        TokenType     = 'Bearer'
        TokenExpiry   = [DateTime]::MinValue
    }

    if (HasValue $ctx.Common.DebugFile) {
        $proxyUrl = if ($ctx.Common.ProxyConfig.Url) { [string]$ctx.Common.ProxyConfig.Url } else { '<none>' }
        Write-CommonDebug -Context $ctx.Common -Message ("CI Effective: ApiUrl={0}; ProxyUrl={1}; Version={2}; CfgPath={3}" -f $ctx.ApiUrl,$proxyUrl,$ctx.Common.Version,$ctx.Common.ConfigPath)
        Write-CommonDebug -Context $ctx.Common -Message ("CI Params: Company={0}; KeyProp={1}; Language={2}; Criticality={3}" -f $ctx.CompanyName,$ctx.KeyProperty,$ctx.Language,$ctx.Criticality)
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
        Optional request body string (e.g., JSON).
    .OUTPUTS
        The structured response object returned by Invoke-LoginWebRequest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [hashtable]$Headers,
        [string]$Body
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

    $resp = Invoke-LoginWebRequest -Method $Method -Uri $uri -Headers $hdr -Body $Body -ProxyConfig $Context.Common.ProxyConfig -DebugFile $Context.Common.DebugFile

    # One-time refresh on auth failure
    if (-not $resp.IsSuccess -and ($resp.StatusCode -in 401,403,498,499)) {
        Write-CommonDebug -Context $Context.Common -Message ("Auth failed (HTTP {0}), refreshing token and retrying once..." -f $resp.StatusCode)
        $Context.AccessToken = $null
        $Context.TokenExpiry = [DateTime]::MinValue
        $token = Get-CIAccessToken -Context $Context
        $hdr['Authorization'] = "{0} {1}" -f $Context.TokenType, $token
        $resp = Invoke-LoginWebRequest -Method $Method -Uri $uri -Headers $hdr -Body $Body -ProxyConfig $Context.Common.ProxyConfig -DebugFile $Context.Common.DebugFile
    }

    return $resp
}
