function ConvertTo-NormalizedUrl {
    <#
    .SYNOPSIS
        Normalizes a URL by unescaping and then re-escaping path and query parts to avoid mixed/double encoding.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RawUri)

    # Extract origin + rest.
    $origin = ''
    $rest   = $RawUri
    $m = [regex]::Match($RawUri, '^(?<origin>https?://[^/?#]+)(?<rest>/.*)?$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
        $origin = $m.Groups['origin'].Value
        $rest   = if ($m.Groups['rest'].Success) { $m.Groups['rest'].Value } else { '' }
    }

    # Extract fragment (#...).
    $frag = ''
    $hi = $rest.IndexOf('#')
    if ($hi -ge 0) {
        $frag = $rest.Substring($hi)   # includes '#'
        $rest = $rest.Substring(0, $hi)
    }

    # Split path / query.
    $path  = $rest
    $query = ''
    $qi = $rest.IndexOf('?')
    if ($qi -ge 0) {
        $path  = $rest.Substring(0, $qi)
        $query = $rest.Substring($qi + 1)
    }

    # Path segments: unescape -> escape (prevents double-encoding).
    $segs = $path -split '/'
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if ($segs[$i] -eq '') { continue }
        $rawSeg   = [System.Uri]::UnescapeDataString([string]$segs[$i])
        $segs[$i] = [System.Uri]::EscapeDataString($rawSeg)
    }
    $encPath = ($segs -join '/')
    if ($path.StartsWith('/')) { $encPath = '/' + $encPath.TrimStart('/') }

    # Query parameters: unescape -> escape per name/value.
    $encQuery = ''
    if ($query) {
        $pairs = New-Object System.Collections.Generic.List[string]
        foreach ($p in ($query -split '&')) {
            if (-not $p) { continue }
            $kv = $p -split '=', 2

            $kRaw = ''
            if ($kv.Count -gt 0 -and $null -ne $kv[0]) { $kRaw = [string]$kv[0] }
            $vRaw = ''
            if ($kv.Count -gt 1 -and $null -ne $kv[1]) { $vRaw = [string]$kv[1] }

            $kEnc = [System.Uri]::EscapeDataString([System.Uri]::UnescapeDataString($kRaw))
            $vEnc = [System.Uri]::EscapeDataString([System.Uri]::UnescapeDataString($vRaw))
            $pairs.Add("$kEnc=$vEnc")
        }
        $encQuery = ($pairs -join '&')
    }

    $rebuilt = $origin + $encPath
    if ($encQuery) { $rebuilt += '?' + $encQuery }
    if ($frag)     { $rebuilt += $frag }
    return $rebuilt
}



function Invoke-LoginWebRequest {
    <#
    .SYNOPSIS
        Unified HTTP request wrapper with proxy support, retries, and debug logging for PS5/PS7.
    .DESCRIPTION
        Performs an HTTP call using Invoke-RestMethod (PS7+) or Invoke-WebRequest (PS5) while:
          - Normalizing the URL
          - Respecting optional headers/body
          - Supporting proxies with explicit credentials or default credentials
          - Capturing raw response bytes to a temp file, then decoding with the correct charset
          - Retrying transient 5xx responses for GET with exponential backoff
          - Returning a structured result without throwing on HTTP errors
    .PARAMETER ProxyConfig
        @{ Url=...; Username=...; Password=...; UseDefaultCredentials=$true|$false;
           BypassProxyOnLocal=$true|$false; BypassList=@('*.intern.local','<local>') }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateSet('GET','POST','PUT','PATCH','DELETE')] [string]$Method,
        [Parameter(Mandatory=$true)][string]$Uri,
        [hashtable]$Headers,
        [string]$Body,
        [hashtable]$ProxyConfig,     # optional
        [string]$DebugFile           # optional log file
    )

    $params = @{
        Method      = $Method
        ErrorAction = 'Stop'
    }
    if ($Headers) { $params.Headers = $Headers }
    if ($Body) {
        $contentType = 'application/json; charset=utf-8'
        if ($Headers -and $Headers.ContainsKey('Content-Type') -and $Headers['Content-Type']) {
            $contentType = [string]$Headers['Content-Type']
        }
        $params.ContentType = $contentType
        $params.Body        = $Body
    }

    # Normalize URL.
    $normUri = ConvertTo-NormalizedUrl -RawUri $Uri
    $params.Uri = $normUri
    if ($DebugFile -and $Uri -ne $normUri) {
        "{0:O} |  URL normalized: {1} -> {2}" -f (Get-Date).ToUniversalTime(), $Uri, $normUri |
            Out-File -FilePath $DebugFile -Append -Encoding UTF8
    }

    $isPS7 = $PSVersionTable.PSVersion.Major -ge 7
    if ($isPS7) {
        $params.SkipHttpErrorCheck = $true
        $params.StatusCodeVariable = 'status'
    }

    # ---------- Proxy initialisation (works like customer's global snippet) ----------
    $webProxy = $null
    $params.Proxy = $null
    if ($ProxyConfig -and $ProxyConfig.Url) {
        try {
            $proxyUrl = [string]$ProxyConfig.Url
            if ($proxyUrl -and $proxyUrl -notmatch '^\w+://') { $proxyUrl = 'http://' + $proxyUrl }

            $webProxy = New-Object System.Net.WebProxy($proxyUrl)

            # Bypass behaviour
            $bypassLocal = if ($ProxyConfig.ContainsKey('BypassProxyOnLocal')) { [bool]$ProxyConfig.BypassProxyOnLocal } else { $true }
            $webProxy.BypassProxyOnLocal = $bypassLocal
            if ($ProxyConfig.ContainsKey('BypassList') -and $ProxyConfig.BypassList) {
                $webProxy.BypassList = @($ProxyConfig.BypassList)
            }

            # Credentials
            if ($ProxyConfig.Username) {
                $sec  = if ($ProxyConfig.Password) { ConvertTo-SecureString ([string]$ProxyConfig.Password) -AsPlainText -Force } else { (New-Object SecureString) }
                $nc   = New-Object System.Net.NetworkCredential
                $nc.UserName       = [string]$ProxyConfig.Username
                $nc.SecurePassword = $sec
                $webProxy.Credentials = $nc

                # For PS cmdlets:
                $params.ProxyCredential = New-Object System.Management.Automation.PSCredential ($nc.UserName, $sec)
            }
            else {
                # Default creds if explicitly requested OR when only URL is given (most corp proxies)
                if ($ProxyConfig.UseDefaultCredentials -or -not $ProxyConfig.ContainsKey('UseDefaultCredentials')) {
                    $webProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
                    $params.ProxyUseDefaultCredentials = $true
                }
            }

            # Pass to cmdlets
            $params.Proxy = $webProxy.Address.AbsoluteUri

            # In PS5 also set global DefaultWebProxy like the customer's snippet
            if (-not $isPS7) {
                [System.Net.WebRequest]::DefaultWebProxy = $webProxy
                if ($webProxy.Credentials) {
                    [System.Net.WebRequest]::DefaultWebProxy.Credentials = $webProxy.Credentials
                }
            }

            if ($DebugFile) {
                $bpList = '-'
                if ($webProxy -and $webProxy.BypassList -and $webProxy.BypassList.Length -gt 0) {
                    $bpList = ($webProxy.BypassList -join ',')
                }

                "{0:O} |  Proxy init: {1} | Mode={2} | BypassLocal={3} | BypassList={4}" -f (Get-Date).ToUniversalTime(),
                    $params.Proxy, $mode, $webProxy.BypassProxyOnLocal, $bpList |
                    Out-File -FilePath $DebugFile -Append -Encoding UTF8
            }
        } catch {
            if ($DebugFile) {
                "{0:O} |  Proxy init ERROR: {1}" -f (Get-Date).ToUniversalTime(), $_ |
                    Out-File -FilePath $DebugFile -Append -Encoding UTF8
            }
        }
    }

    # Debug log (headers masked).
    if ($DebugFile) {
        $maskedHeaders = $null
        if ($Headers) {
            $maskedHeaders = @{}
            foreach ($k in $Headers.Keys) {
                $v = [string]$Headers[$k]
                if ($k -match 'api-key' -or $k -match 'authorization') {
                    $tail = if ($v.Length -ge 4) { $v.Substring($v.Length - 4) } else { $v }
                    $maskedHeaders[$k] = ('***' + $tail)
                } else { $maskedHeaders[$k] = $v }
            }
        }
        "{0:O} | HTTP {1} {2}" -f (Get-Date).ToUniversalTime(), $Method, $params.Uri | Out-File -FilePath $DebugFile -Append -Encoding UTF8
        if ($maskedHeaders) { "{0:O} |  Headers: {1}" -f (Get-Date).ToUniversalTime(), (ConvertTo-Json $maskedHeaders -Depth 5) | Out-File -FilePath $DebugFile -Append -Encoding UTF8 }
        if ($Body)          { "{0:O} |  BodyLen: {1}; ContentType: {2}" -f (Get-Date).ToUniversalTime(), $Body.Length, $params.ContentType | Out-File -FilePath $DebugFile -Append -Encoding UTF8 }
        if ($params.Proxy)  { "{0:O} |  Proxy: {1}" -f (Get-Date).ToUniversalTime(), $params.Proxy | Out-File -FilePath $DebugFile -Append -Encoding UTF8 }
    }

    # ---- Unified request (PS5: IWR, PS7+: IRM) with raw bytes + retry on 5xx ----
    $maxAttempts = 3
    $baseDelayMs = 400
    $attempt     = 0

    while ($true) {
        $attempt++
        $tmpFile     = [System.IO.Path]::GetTempFileName()
        $respHeaders = $null
        $statusCode  = $null
        $statusDesc  = ''
        $shouldRetry = $false

        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'

        try {
            if ($isPS7) {
                $irmParams = @{
                    Uri                     = $params['Uri']
                    Method                  = $params['Method']
                    Headers                 = $params['Headers']
                    OutFile                 = $tmpFile
                    ErrorAction             = 'Stop'
                    SkipHttpErrorCheck      = $true
                    StatusCodeVariable      = 'status'
                    ResponseHeadersVariable = 'respHeaders'
                }
                if ($params.ContainsKey('Body'))           { $irmParams.Body        = $params['Body'] }
                if ($params.ContainsKey('ContentType'))    { $irmParams.ContentType = $params['ContentType'] }
                if ($params['Proxy'])                      { $irmParams.Proxy       = $params['Proxy'] }
                if ($params['ProxyUseDefaultCredentials']) { $irmParams.ProxyUseDefaultCredentials = $params['ProxyUseDefaultCredentials'] }
                if ($params['ProxyCredential'])            { $irmParams.ProxyCredential = $params['ProxyCredential'] }

                $null = Invoke-RestMethod @irmParams
                $statusCode = $status
            } else {
                $iwrParams = @{
                    Uri             = $params['Uri']
                    Method          = $params['Method']
                    Headers         = $params['Headers']
                    OutFile         = $tmpFile
                    UseBasicParsing = $true
                    ErrorAction     = 'Stop'
                    PassThru        = $true
                }
                if ($params.ContainsKey('Body'))           { $iwrParams.Body        = $params['Body'] }
                if ($params.ContainsKey('ContentType'))    { $iwrParams.ContentType = $params['ContentType'] }
                if ($params['Proxy'])                      { $iwrParams.Proxy       = $params['Proxy'] }
                if ($params['ProxyUseDefaultCredentials']) { $iwrParams.ProxyUseDefaultCredentials = $params['ProxyUseDefaultCredentials'] }
                if ($params['ProxyCredential'])            { $iwrParams.ProxyCredential = $params['ProxyCredential'] }

                $respObj     = Invoke-WebRequest @iwrParams
                $respHeaders = $respObj.Headers
                $statusCode  = 200
                $statusDesc  = 'OK'
            }

            $bytes = [System.IO.File]::ReadAllBytes($tmpFile)
            Remove-Item $tmpFile -ErrorAction SilentlyContinue

            if ($isPS7) {
                if ($Method -eq 'GET' -and $statusCode -ge 500 -and $statusCode -lt 600 -and $attempt -lt $maxAttempts) {
                    $shouldRetry = $true
                }
            }

            if ($shouldRetry) {
                if ($DebugFile) {
                    "{0:O} |  RETRY {1}/{2} after HTTP {3} (PS7), will backoff" -f (Get-Date).ToUniversalTime(), $attempt, $maxAttempts, $statusCode |
                        Out-File -FilePath $DebugFile -Append -Encoding UTF8
                }
                $delay = [int]([math]::Round($baseDelayMs * [math]::Pow(2, $attempt-1) + (Get-Random -Minimum 0 -Maximum 150)))
                Start-Sleep -Milliseconds $delay
                continue
            }

            $ct = ''
            if ($respHeaders -and $respHeaders['Content-Type']) { $ct = [string]$respHeaders['Content-Type'] }
            $encodingName = 'utf-8'
            if ($ct -and ($ct -notmatch 'application/json') -and ($ct -match 'charset=([^;]+)')) { $encodingName = $Matches[1] }
            try { $enc = [System.Text.Encoding]::GetEncoding($encodingName) } catch { $enc = [System.Text.Encoding]::UTF8 }
            $bodyText = $enc.GetString($bytes)

            return [pscustomobject]@{
                IsSuccess         = $true
                StatusCode        = $statusCode
                StatusDescription = $statusDesc
                Headers           = $respHeaders
                Body              = $bodyText
            }
        }
        catch [System.Net.WebException] {
            $resp = $_.Exception.Response
            $code = $null; $desc = $null; $errText = $null
            if ($resp) {
                try {
                    $code = [int]$resp.StatusCode
                    $desc = [string]$resp.StatusDescription
                    $errText = Get-HttpErrorBody -ErrorRecord $_
                } catch {}
            }
            if (Test-Path $tmpFile) { Remove-Item $tmpFile -ErrorAction SilentlyContinue }

            if ($Method -eq 'GET' -and $code -ge 500 -and $code -lt 600 -and $attempt -lt $maxAttempts) {
                if ($DebugFile) {
                    "{0:O} |  RETRY {1}/{2} after HTTP {3} {4}" -f (Get-Date).ToUniversalTime(), $attempt, $maxAttempts, $code, $desc |
                        Out-File -FilePath $DebugFile -Append -Encoding UTF8
                }
                $delay = [int]([math]::Round($baseDelayMs * [math]::Pow(2, $attempt-1) + (Get-Random -Minimum 0 -Maximum 150)))
                Start-Sleep -Milliseconds $delay
                continue
            }

            if ($DebugFile) {
                $bodyPreview = ""
                if ($null -ne $errText -and $errText.Length -gt 0) {
                    $bodyPreview = " Body=" + $errText.Substring(0, [Math]::Min(2000, $errText.Length))
                }
                "{0:O} |  ERROR: HTTP {1} {2}{3}" -f (Get-Date).ToUniversalTime(), $code, $desc, $bodyPreview |
                    Out-File -FilePath $DebugFile -Append -Encoding UTF8
            }
            return [pscustomobject]@{
                IsSuccess         = $false
                StatusCode        = if ($code) { $code } else { 0 }
                StatusDescription = if ($desc) { $desc } else { $_.Exception.Message }
                Body              = $errText
            }
        }
        catch {
            if (Test-Path $tmpFile) { Remove-Item $tmpFile -ErrorAction SilentlyContinue }
            if ($DebugFile) {
                "{0:O} |  ERROR: {1}" -f (Get-Date).ToUniversalTime(), $_ |
                    Out-File -FilePath $DebugFile -Append -Encoding UTF8
            }
            return [pscustomobject]@{
                IsSuccess         = $false
                StatusCode        = 0
                StatusDescription = $_.Exception.Message
                Body              = ""
            }
        }
        finally {
            $ProgressPreference = $oldProgress
        }
    }
}

function Get-HttpErrorBody {
    param(
        [Parameter(Mandatory)]
        $ErrorRecord
    )

    # Prefer ErrorDetails when present (PowerShell often stores response body there)
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            return [string]$ErrorRecord.ErrorDetails.Message
        }
    } catch { }

    # Fallback: try to read from WebException.Response stream (HttpWebResponse)
    try {
        $ex = $ErrorRecord.Exception
        if ($ex -is [System.Net.WebException] -and $ex.Response) {
            $resp = $ex.Response

            $stream = $resp.GetResponseStream()
            if ($stream) {
                try {
                    $ms = New-Object System.IO.MemoryStream
                    try {
                        $stream.CopyTo($ms)

                        $enc = [System.Text.Encoding]::UTF8
                        $ct = $resp.Headers['Content-Type']
                        if ($ct -match 'charset=([^;]+)') {
                            try { $enc = [System.Text.Encoding]::GetEncoding($Matches[1]) } catch { }
                        }

                        return $enc.GetString($ms.ToArray())
                    }
                    finally {
                        $ms.Dispose()
                    }
                }
                finally {
                    $stream.Dispose()
                }
            }
        }
    } catch { }

    # Last resort
    return $ErrorRecord.ToString()
}

