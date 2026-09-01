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



function ConvertTo-GzipBytes {
    <#
    .SYNOPSIS
        Compresses a [string] (as UTF-8, no BOM) or a [byte[]] with gzip (RFC 1952) and returns the compressed bytes.
    .DESCRIPTION
        Uses System.IO.Compression.GZipStream, which is part of every supported runtime:
          - Windows PowerShell 5.1 / .NET Framework 4.5+ : System.dll (always loaded)
          - PowerShell 7+ / .NET                         : System.IO.Compression.dll (shared framework)
        No additional assemblies, Add-Type calls or third-party modules are required.
    .PARAMETER InputObject
        The data to compress: [string] (UTF-8 encoded first) or [byte[]].
    .OUTPUTS
        [byte[]] gzip-compressed data (returned as a single array, not enumerated).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowEmptyString()][AllowEmptyCollection()][object]$InputObject)

    if ($InputObject -is [byte[]])    { $bytes = $InputObject }
    elseif ($InputObject -is [string]) { $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputObject) }
    else { throw ("ConvertTo-GzipBytes expects [string] or [byte[]], got {0}" -f $InputObject.GetType().FullName) }

    if ($bytes.Length -eq 0) {
        # GZipStream emits nothing at all when no data was written (both .NET Framework and .NET);
        # return the canonical empty gzip member instead (10-byte header, empty final deflate block, CRC32=0, ISIZE=0).
        return ,([byte[]](0x1f,0x8b,0x08,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00, 0x03,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00))
    }

    $ms = New-Object System.IO.MemoryStream
    try {
        # leaveOpen=$true so the MemoryStream survives disposing the GZipStream.
        # Disposing the GZipStream is REQUIRED: it flushes the final deflate block and writes the gzip trailer (CRC32 + ISIZE).
        $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress, $true)
        try { $gz.Write($bytes, 0, $bytes.Length) } finally { $gz.Dispose() }
        # Unary comma prevents PowerShell from unrolling the byte[] into individual pipeline objects.
        return ,($ms.ToArray())
    }
    finally { $ms.Dispose() }
}

function Invoke-LoginWebRequest {
    <#
    .SYNOPSIS
        Unified HTTP request wrapper with proxy support, retries, and debug logging for PS5/PS7.
    .DESCRIPTION
        Performs an HTTP call using Invoke-RestMethod (PS7+) or Invoke-WebRequest (PS5) while:
          - Normalizing the URL
          - Respecting optional headers/body ([string] or raw [byte[]] body)
          - Optionally gzip-compressing the request body (-GzipBody) and sending "Content-Encoding: gzip"
          - Supporting proxies with explicit credentials or default credentials
          - Capturing raw response bytes to a temp file, then decoding with the correct charset
          - Retrying transient 5xx responses for GET with exponential backoff
          - Returning a structured result without throwing on HTTP errors
    .PARAMETER Body
        Request body as [string] (sent as text, default Content-Type "application/json; charset=utf-8")
        or as [byte[]] (sent as-is, e.g. pre-compressed data).
    .PARAMETER GzipBody
        Compresses the body with gzip before sending and adds the header "Content-Encoding: gzip".
        A [string] body is UTF-8 encoded first. The server must support gzip request bodies.
    .PARAMETER ProxyConfig
        @{ Url=...; Username=...; Password=...; UseDefaultCredentials=$true|$false;
           BypassProxyOnLocal=$true|$false; BypassList=@('*.intern.local','<local>') }
    .OUTPUTS
        PSCustomObject with IsSuccess, StatusCode, StatusDescription, Headers, Body,
        RequestBodyLength (length of the body actually sent) and RequestEncoding ('gzip' or '').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateSet('GET','POST','PUT','PATCH','DELETE')] [string]$Method,
        [Parameter(Mandatory=$true)][string]$Uri,
        [hashtable]$Headers,
        [object]$Body,               # [string] or [byte[]]
        [switch]$GzipBody,           # gzip-compress the body and add "Content-Encoding: gzip"
        [hashtable]$ProxyConfig,     # optional
        [string]$DebugFile           # optional log file
    )

    # Work on a copy of the headers so the caller's hashtable is never mutated.
    $reqHeaders = @{}
    if ($Headers) { foreach ($k in $Headers.Keys) { $reqHeaders[$k] = $Headers[$k] } }

    # ---------- Body normalization: [string] or [byte[]] ----------
    $hasBody = $false
    if ($null -ne $Body) {
        if ($Body -is [byte[]]) {
            $hasBody = ($Body.Length -gt 0)
        }
        else {
            if (-not ($Body -is [string])) { $Body = [string]$Body }
            $hasBody = ($Body.Length -gt 0)
        }
    }

    # ---------- Optional gzip compression of the request body ----------
    $rawBodyLength   = if ($hasBody) { $Body.Length } else { 0 }
    $requestEncoding = ''
    if ($hasBody -and $GzipBody) {
        $Body = ConvertTo-GzipBytes -InputObject $Body
        $requestEncoding = 'gzip'
        # Replace any caller-provided Content-Encoding (case-insensitive); stacked encodings are not supported.
        foreach ($k in @($reqHeaders.Keys)) { if ($k -ieq 'Content-Encoding') { $reqHeaders.Remove($k) } }
        $reqHeaders['Content-Encoding'] = 'gzip'
    }
    elseif ($hasBody) {
        foreach ($k in $reqHeaders.Keys) { if ($k -ieq 'Content-Encoding') { $requestEncoding = [string]$reqHeaders[$k] } }
    }

    $params = @{
        Method      = $Method
        ErrorAction = 'Stop'
    }
    if ($reqHeaders.Count -gt 0) { $params.Headers = $reqHeaders }
    if ($hasBody) {
        $contentType = 'application/json; charset=utf-8'
        foreach ($k in $reqHeaders.Keys) {
            if ($k -ieq 'Content-Type' -and $reqHeaders[$k]) { $contentType = [string]$reqHeaders[$k] }
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
                # ($mode was previously undefined here, which made StrictMode log "Proxy init ERROR" instead of this line)
                $proxyMode = if ($ProxyConfig.Username) { 'ExplicitCredentials' } elseif ($params['ProxyUseDefaultCredentials']) { 'DefaultCredentials' } else { 'Anonymous' }

                "{0:O} |  Proxy init: {1} | Mode={2} | BypassLocal={3} | BypassList={4}" -f (Get-Date).ToUniversalTime(),
                    $params.Proxy, $proxyMode, $webProxy.BypassProxyOnLocal, $bpList |
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
        if ($reqHeaders.Count -gt 0) {
            $maskedHeaders = @{}
            foreach ($k in $reqHeaders.Keys) {
                $v = [string]$reqHeaders[$k]
                if ($k -match 'api-key' -or $k -match 'authorization') {
                    $tail = if ($v.Length -ge 4) { $v.Substring($v.Length - 4) } else { $v }
                    $maskedHeaders[$k] = ('***' + $tail)
                } else { $maskedHeaders[$k] = $v }
            }
        }
        "{0:O} | HTTP {1} {2}" -f (Get-Date).ToUniversalTime(), $Method, $params.Uri | Out-File -FilePath $DebugFile -Append -Encoding UTF8
        if ($maskedHeaders) { "{0:O} |  Headers: {1}" -f (Get-Date).ToUniversalTime(), (ConvertTo-Json $maskedHeaders -Depth 5) | Out-File -FilePath $DebugFile -Append -Encoding UTF8 }
        if ($hasBody) {
            if ($GzipBody) {
                $bodyInfo = "BodyLen: {0} bytes (gzip; uncompressed {1}); ContentType: {2}" -f $Body.Length, $rawBodyLength, $params.ContentType
            }
            elseif ($Body -is [byte[]]) {
                $encInfo  = if ($requestEncoding) { "; Content-Encoding: $requestEncoding" } else { '' }
                $bodyInfo = "BodyLen: {0} bytes (binary{1}); ContentType: {2}" -f $Body.Length, $encInfo, $params.ContentType
            }
            else {
                $bodyInfo = "BodyLen: {0}; ContentType: {1}" -f $Body.Length, $params.ContentType
            }
            "{0:O} |  {1}" -f (Get-Date).ToUniversalTime(), $bodyInfo | Out-File -FilePath $DebugFile -Append -Encoding UTF8
        }
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

            # PS5 only reaches this point with HTTP 2xx (errors throw WebException); with -SkipHttpErrorCheck
            # PS7 also lands here for 4xx/5xx, so derive IsSuccess from the status code on both engines.
            return [pscustomobject]@{
                IsSuccess         = ($null -ne $statusCode -and [int]$statusCode -ge 200 -and [int]$statusCode -lt 300)
                StatusCode        = $statusCode
                StatusDescription = $statusDesc
                Headers           = $respHeaders
                Body              = $bodyText
                RequestBodyLength = $(if ($hasBody) { $Body.Length } else { 0 })
                RequestEncoding   = $requestEncoding
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
                Headers           = $null
                Body              = $errText
                RequestBodyLength = $(if ($hasBody) { $Body.Length } else { 0 })
                RequestEncoding   = $requestEncoding
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
                Headers           = $null
                Body              = ""
                RequestBodyLength = $(if ($hasBody) { $Body.Length } else { 0 })
                RequestEncoding   = $requestEncoding
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

