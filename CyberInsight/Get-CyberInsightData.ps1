#requires -Version 5.1
<#
    File:        Get-CyberInsightData.ps1
    Purpose:     Pull vulnerable software and device mappings from the CyberInsight API,
                 serialize results to LOGINventory .inv files, and emit standard notifications.

    Flow:
      1) Build Common context (encoding, debug, proxy) via New-CommonContext
      2) Build CI-specific context via New-CIContext
      3) Resolve company by name -> companyId
      4) Page through vulnerable software (cursor based, sequential)
      5) Process every software in parallel workers (runspace pool): page its expanded
         vulnerabilities and affected devices, stream the software .inv file straight to disk
      6) Collect the device -> (software, vulnerability) mapping in a compact in-memory structure
      7) Emit the differential cleanup .inv and one .inv file per device

    Key features:
      * Parallel workers (CyberInsightParallelism, default 8), each with its own bearer token
      * Retries with backoff for transient errors (network/DNS, 408/429/5xx), also for token requests
      * A software that keeps failing is reported and skipped; the run continues
        (a long streak of consecutive failures aborts the run)
      * .inv files are streamed with XmlWriter (no entity list / string / XmlDocument copies in memory)
        and written to <name>.tmp first, then renamed
      * Software without matching vulnerabilities does not trigger a device request
      * Device mapping keeps only references to interned vulnerability ids (a few bytes per pair)
      * Standardized Notify() messages for external log collectors

    Requirements:
      - include\common.ps1
      - include\WebRequest.ps1
      - cyberinsight-common.ps1
#>

param (
    [string]$parameter = ""
)

Set-StrictMode -Version Latest

# Includes analogous to the POST script
. (Join-Path -Path $PSScriptRoot -ChildPath "..\include\common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "..\include\WebRequest.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "cyberinsight-common.ps1")

function Start-CyberInsightGet {
    <#
    .SYNOPSIS
        Entry point to fetch data from CyberInsight and write .inv files.
    .PARAMETER params
        Encoded parameter blob (same format used by New-CommonContext).
    #>
    [CmdletBinding()]
    param([string]$params = "")

    # 1) Build Common context (encoding, debug & proxy)
    $common = New-CommonContext -Parameters $params -StartLabel 'CI'
    # 2) Build CI domain context
    $ctx = New-CIContext -Common $common

    Write-CommonDebug -Context $ctx.Common -Message ("Effective Config: Url={0}, Company={1}, Language={2}, ProxyActive={3}, Parallelism={4}" -f $ctx.ApiUrl, $ctx.CompanyName, $ctx.Language, $ctx.Common.ProxyConfig.Active, $ctx.Parallelism)

    $pool = $null
    $running = New-Object System.Collections.Generic.List[object]

    try {
        function Get-CICompanyId {
            param([Parameter(Mandatory)]$Context)

            Write-CommonDebug -Context $Context.Common -Message "GET companies"
            $resp = Invoke-CIApiRetry -Context $Context -Path "companies"
            if (-not $resp.IsSuccess) { throw "Companies failed: HTTP $($resp.StatusCode) $($resp.StatusDescription)" }

            $companies = $resp.Body | ConvertFrom-Json
            $company   = $companies | Where-Object { $_.name -eq $Context.CompanyName } | Select-Object -First 1
            if (-not $company) { throw "Company '$($Context.CompanyName)' not found." }

            Write-CommonDebug -Context $Context.Common -Message ("CompanyId = {0}" -f $company.id)
            return $company.id
        }

        function Get-CIVulnerableSoftwarePage {
            param(
                [Parameter(Mandatory)]$Context,
                [Parameter(Mandatory)][string]$CompanyId,
                [int]$PageSize = 10,
                [decimal]$StartAfterDaraScore
            )

            $qs = @("minimum_page_size=$PageSize")
            if ($PSBoundParameters.ContainsKey('StartAfterDaraScore') -and $StartAfterDaraScore -gt 0) {
                $qs += "start_after=$StartAfterDaraScore"
            }
            $path = "companies/{0}/vulnerable_softwares?{1}" -f $CompanyId, ($qs -join '&')

            Write-CommonDebug -Context $Context.Common -Message ("GET vulnerable_softwares: {0}" -f $path)
            $resp = Invoke-CIApiRetry -Context $Context -Path $path
            if (-not $resp.IsSuccess) { throw "Vulnerable software failed: HTTP $($resp.StatusCode) $($resp.StatusDescription)" }
            return @($resp.Body | ConvertFrom-Json)
        }

        # --- Worker: runs inside a runspace of the pool ----------------------------
        # Fetches vulnerabilities + affected devices of ONE software, streams the software .inv file
        # and returns a small result hashtable. Has no debug file; log lines are returned instead.
        $ciWorker = {
            param($Cfg, $CompanyId, $Sw, $FilePath, $Version, $VulnPageSize, $DevPageSize, $Criticality, $KeyProperty, $Intern)

            $log    = New-Object System.Collections.Generic.List[string]
            $result = @{ Ok = $false; Error = ''; SoftwareId = $Sw.id; VulnCount = 0; DeviceCount = 0; Devices = $null; File = $FilePath; Log = $log; Seconds = 0.0 }
            $clock  = [System.Diagnostics.Stopwatch]::StartNew()
            $inv    = $null
            try {
                # One context (= one bearer token) per runspace, kept in the runspace's global scope
                $c = Get-Variable -Name CIWorkerCtx -Scope Global -ValueOnly -ErrorAction SilentlyContinue
                if (-not $c) {
                    # Built from plain values (no sharing of the main context object between threads)
                    $c = [pscustomobject]@{
                        Common      = [pscustomobject]@{ DebugFile = $null; ProxyConfig = $Cfg.ProxyConfig; Version = $Cfg.Version }
                        ApiUrl      = $Cfg.ApiUrl
                        ApiKey      = $Cfg.ApiKey
                        Language    = $Cfg.Language
                        AccessToken = $null
                        TokenType   = 'Bearer'
                        TokenExpiry = [DateTime]::MinValue
                    }
                    Set-Variable -Name CIWorkerCtx -Scope Global -Value $c
                }

                $critQs = ''
                if ($Criticality) { $critQs = '&' + ((($Criticality -split '\|') | ForEach-Object { 'criticality=' + $_.Trim() }) -join '&') }
                $inv_ci = [System.Globalization.CultureInfo]::InvariantCulture

                $inv = Open-CIInv -FilePath $FilePath -Version $Version -Entity 'SoftwarePackage'
                $w = $inv.Writer
                $w.WriteElementString('Name',               (ConvertTo-CIXmlText $Sw.software_name))
                $w.WriteElementString('Version',            (ConvertTo-CIXmlText $Sw.software_version))
                $w.WriteElementString('Publisher',          (ConvertTo-CIXmlText $Sw.software_publisher))
                $w.WriteElementString('Platform',           (ConvertTo-CIXmlText $Sw.software_metadata))
                $w.WriteElementString('VulnerabilityScore', ([math]::Round($Sw.dara_score_sum * 10, 2, [System.MidpointRounding]::AwayFromZero)).ToString($inv_ci))
                $w.WriteElementString('SoftwareId',         ([string]$Sw.id))

                # --- expanded vulnerabilities -> streamed into the software .inv ---
                $startAfter = $null
                $vulnCount  = 0
                do {
                    $path = "companies/{0}/vulnerable_softwares/{1}/expanded_vulnerabilities?page_size={2}{3}" -f $CompanyId, $Sw.id, $VulnPageSize, $critQs
                    if ($startAfter) { $path += "&start_after=$startAfter" }
                    $t0 = $clock.ElapsedMilliseconds
                    $resp = Invoke-CIApiRetry -Context $c -Path $path -LogSink $log
                    if (-not $resp.IsSuccess) { throw "Vulnerabilities failed: HTTP $($resp.StatusCode) $($resp.StatusDescription)" }
                    $t1 = $clock.ElapsedMilliseconds
                    $parsed = $resp.Body | ConvertFrom-Json
                    $vulns = @(); if ($null -ne $parsed) { $vulns = @($parsed) }   # PS 5.1 emits a JSON array as ONE object; @() keeps it flat
                    $resp = $null
                    $log.Add(("GET {0}: {1} items, request {2} ms, parse {3} ms" -f $path, $vulns.Count, ($t1 - $t0), ($clock.ElapsedMilliseconds - $t1)))

                    foreach ($v in $vulns) {
                        $w.WriteStartElement('Vulnerabilities')
                        $w.WriteElementString('Name',                  (ConvertTo-CIXmlText $v.ci_id))
                        $w.WriteElementString('Score',                 ([math]::Round($v.dara_score * 10, 2, [System.MidpointRounding]::AwayFromZero)).ToString($inv_ci))
                        $w.WriteElementString('Description',           (ConvertTo-CIXmlText $v.description))
                        $w.WriteElementString('AttackVector',          ("$($v.attack_vector)"))
                        $w.WriteElementString('AttackComplexity',      ("$($v.attack_complexity)"))
                        $w.WriteElementString('PrivilegesRequired',    ("$($v.privileges_required)"))
                        $w.WriteElementString('UserInteraction',       ("$($v.user_interaction)"))
                        $w.WriteElementString('Scope',                 ("$($v.scope)"))
                        $w.WriteElementString('ConfidentialityImpact', ("$($v.confidentiality)"))
                        $w.WriteElementString('IntegrityImpact',       ("$($v.integrity)"))
                        $w.WriteElementString('AvailabilityImpact',    ("$($v.availability)"))
                        $w.WriteElementString('IsExploitable',         ("$($v.is_exploitable)"))
                        $w.WriteElementString('SoftwareId',            ([string]$Sw.id))
                        $w.WriteEndElement()
                    }
                    $vulnCount += $vulns.Count
                    $startAfter = if ($vulns.Count -gt 0) { [string]$vulns[-1].ci_id } else { $null }
                    $more = ($vulns.Count -ge $VulnPageSize)
                    $vulns = $null
                } while ($more)
                $result.VulnCount = $vulnCount

                # --- affected devices (only if there is at least one matching vulnerability) ---
                $devMap = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' ([System.StringComparer]::OrdinalIgnoreCase)
                if ($vulnCount -gt 0) {
                    $startAfter = $null
                    do {
                        $path = "companies/{0}/vulnerable_softwares/{1}/vulnerabilities/devices?page_size={2}{3}" -f $CompanyId, $Sw.id, $DevPageSize, $critQs
                        if ($startAfter) { $path += "&start_after=$startAfter" }
                        $t0 = $clock.ElapsedMilliseconds
                        $resp = Invoke-CIApiRetry -Context $c -Path $path -LogSink $log
                        if (-not $resp.IsSuccess) { throw "Vulnerability devices failed: HTTP $($resp.StatusCode) $($resp.StatusDescription)" }
                        $t1 = $clock.ElapsedMilliseconds
                        $parsed = $resp.Body | ConvertFrom-Json
                        $vCiDevs = @(); if ($null -ne $parsed) { $vCiDevs = @($parsed) }
                        $resp = $null
                        $log.Add(("GET {0}: {1} items, request {2} ms, parse {3} ms" -f $path, $vCiDevs.Count, ($t1 - $t0), ($clock.ElapsedMilliseconds - $t1)))

                        foreach ($vCi in $vCiDevs) {
                            $ciText = ConvertTo-CIXmlText $vCi.ci_id                  # sanitized once here, so the device writer can write it as is
                            $ciId = $Intern.GetOrAdd($ciText, $ciText)                # one shared string instance per vulnerability id
                            foreach ($d in $vCi.devices) {
                                $deviceKey = if ($KeyProperty -eq 'Name') { [string]$d.name } else { [string]$d.id }
                                if ([string]::IsNullOrWhiteSpace($deviceKey)) { continue }
                                $list = $null
                                if (-not $devMap.TryGetValue($deviceKey, [ref]$list)) {
                                    $list = New-Object 'System.Collections.Generic.List[string]'
                                    $devMap[$deviceKey] = $list
                                }
                                $list.Add($ciId)
                            }
                        }
                        $startAfter = if ($vCiDevs.Count -gt 0) { [string]$vCiDevs[-1].ci_id } else { $null }
                        $more = ($vCiDevs.Count -ge $DevPageSize)
                        $vCiDevs = $null
                    } while ($more)
                }
                $result.Devices     = $devMap
                $result.DeviceCount = $devMap.Count

                Close-CIInv -Handle $inv
                $inv = $null
                $result.Ok = $true
            }
            catch {
                $result.Error = [string]$_.Exception.Message
                if ($inv) { try { Close-CIInv -Handle $inv -Abort } catch {} ; $inv = $null }
            }
            $result.Seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
            return $result
        }

        # --- Main flow -----------------------------------------------------------

        Notify -name "CyberInsightApi" -itemName "Company" -message ("Searching '{0}'" -f $ctx.CompanyName) -category "Info" -state "Executing" -itemResult "None"
        $companyId = Get-CICompanyId -Context $ctx
        Notify -name "CyberInsightApi" -itemName "Company" -message ("Found {0}" -f $ctx.CompanyName) -category "Info" -state "Finished" -itemResult "Ok"

        # Page vulnerable software (cursor = dara_score_sum of the last entry; sequential by nature)
        $softwarePageSize = 100
        $vulnPageSize     = 5000
        $devPageSize      = 5000
        $lastDaraScore    = $null

        $softwareList = New-Object System.Collections.Generic.List[object]
        $seenIds      = New-Object 'System.Collections.Generic.HashSet[string]'

        do {
            $VulnerableSoftware = Get-CIVulnerableSoftwarePage -Context $ctx -CompanyId $companyId -PageSize $softwarePageSize -StartAfterDaraScore $lastDaraScore

            $newOnPage = 0
            foreach ($sw in $VulnerableSoftware) {
                $lastDaraScore = $sw.dara_score_sum
                # Guard against overlapping pages (same cursor value): never queue a software twice
                if (-not $seenIds.Add([string]$sw.id)) { continue }
                $newOnPage++
                Notify -name "$($sw.software_name) [$($sw.software_version)]" -itemName "-" -message "-" -category "Info" -itemResult "None" -state "Queued"
                [void]$softwareList.Add($sw)
            }
            if ($VulnerableSoftware.Count -lt $softwarePageSize) { break }
            if ($newOnPage -eq 0) {
                Write-CommonDebug -Context $ctx.Common -Message ("Software paging made no progress at dara_score_sum={0}; stopping paging" -f $lastDaraScore)
                break
            }
        } while ($true)

        if ($softwareList.Count -eq 0) {
            Notify -name "CyberInsightApi" -itemName "-" -message "No data available yet, please try again later" -category "Error" -state "Faulty" -itemResult "Error"
            exit 1
        }
        Write-CommonDebug -Context $ctx.Common -Message ("Software list complete: {0} entries; processing with {1} parallel workers" -f $softwareList.Count, $ctx.Parallelism)

        # Mapping: device key -> alternating entries [software id, string[] of vulnerability ids]
        $deviceMap = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[object]]' ([System.StringComparer]::OrdinalIgnoreCase)
        $intern    = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,string]'

        # Read-only settings handed to the workers (each worker builds its own context + token from them)
        $workerCfg = @{ ApiUrl = $ctx.ApiUrl; ApiKey = $ctx.ApiKey; Language = $ctx.Language; ProxyConfig = $ctx.Common.ProxyConfig; Version = [string]$ctx.Common.Version }

        $dop  = [Math]::Max(1, [int]$ctx.Parallelism)
        $pool = New-CIWorkerPool -Parallelism $dop

        $total        = $softwareList.Count
        $nextIndex    = 0
        $done         = 0
        $failed       = 0
        $failStreak   = 0
        $maxFailStreak = [Math]::Max(10, $dop * 2)
        $aborted      = $false
        $runClock     = [System.Diagnostics.Stopwatch]::StartNew()

        while (($nextIndex -lt $total -or $running.Count -gt 0) -and -not $aborted) {

            # Keep the pool busy (a small backlog keeps workers from idling while results are processed)
            while ($nextIndex -lt $total -and $running.Count -lt ($dop + 2)) {
                $sw = $softwareList[$nextIndex]
                $nextIndex++

                $timestamp   = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
                # Bounded name parts (the software id keeps the file name unique) so that <DataDir>\<name>.inv.tmp stays below MAX_PATH
                $safeName    = New-SafeFileName $sw.software_name -MaxLength 80
                $safeVersion = New-SafeFileName $sw.software_version -MaxLength 40
                $filePath    = Join-Path $ctx.Common.DataDir ("{0}_ci_{1}_{2}_{3}.inv" -f $timestamp, $safeName, $safeVersion, $sw.id)

                Notify -name "$($sw.software_name) [$($sw.software_version)]" -itemName "Vulnerabilities" -message "Loading" -category "Info" -state "Executing" -itemResult "None"

                $ps = [System.Management.Automation.PowerShell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript($ciWorker.ToString())
                [void]$ps.AddArgument($workerCfg).AddArgument([string]$companyId).AddArgument($sw).AddArgument($filePath).AddArgument([string]$ctx.Common.Version)
                [void]$ps.AddArgument($vulnPageSize).AddArgument($devPageSize).AddArgument([string]$ctx.Criticality).AddArgument([string]$ctx.KeyProperty).AddArgument($intern)
                $running.Add([pscustomobject]@{ Ps = $ps; Handle = $ps.BeginInvoke(); Sw = $sw })
            }

            # Collect finished workers
            $progress = $false
            for ($i = $running.Count - 1; $i -ge 0; $i--) {
                $job = $running[$i]
                if (-not $job.Handle.IsCompleted) { continue }
                $running.RemoveAt($i)
                $progress = $true
                $sw = $job.Sw

                $r = $null
                try {
                    $out = $job.Ps.EndInvoke($job.Handle)
                    if ($out -and $out.Count -gt 0) { $r = $out[$out.Count - 1] }
                    elseif ($job.Ps.Streams.Error.Count -gt 0) { $r = @{ Ok = $false; Error = [string]$job.Ps.Streams.Error[0]; Log = @(); Devices = $null; VulnCount = 0; DeviceCount = 0; Seconds = 0 } }
                    else { $r = @{ Ok = $false; Error = 'Worker returned no result'; Log = @(); Devices = $null; VulnCount = 0; DeviceCount = 0; Seconds = 0 } }
                }
                catch {
                    $r = @{ Ok = $false; Error = [string]$_.Exception.Message; Log = @(); Devices = $null; VulnCount = 0; DeviceCount = 0; Seconds = 0 }
                }
                finally {
                    $job.Ps.Dispose()
                }

                $done++
                foreach ($line in $r.Log) { Write-CommonDebug -Context $ctx.Common -Message ("  [sw {0}] {1}" -f $sw.id, $line) }

                if ($r.Ok) {
                    $failStreak = 0
                    # Merge the device mapping (per device one reference to the vulnerability id list)
                    foreach ($kv in $r.Devices.GetEnumerator()) {
                        $entry = $null
                        if (-not $deviceMap.TryGetValue($kv.Key, [ref]$entry)) {
                            $entry = New-Object 'System.Collections.Generic.List[object]'
                            $deviceMap[$kv.Key] = $entry
                        }
                        $entry.Add($sw.id)
                        $entry.Add($kv.Value)
                    }
                    Write-CommonDebug -Context $ctx.Common -Message ("Software done {0}/{1}: id={2} {3} [{4}] vulns={5} devices={6} {7}s (elapsed {8:N0}s, running {9})" -f $done, $total, $sw.id, $sw.software_name, $sw.software_version, $r.VulnCount, $r.DeviceCount, $r.Seconds, $runClock.Elapsed.TotalSeconds, $running.Count)
                    Notify -name "Vulnerability Data" -itemName "-" -message ("Written to {0}" -f $r.File) -category "Info" -state "Finished" -itemResult "Ok"
                    Notify -name "$($sw.software_name) [$($sw.software_version)]" -itemName "Vulnerabilities" -message "Done" -category "Info" -state "Finished" -itemResult "Ok"
                }
                else {
                    $failed++
                    $failStreak++
                    Write-CommonDebug -Context $ctx.Common -Message ("ERROR software {0}/{1}: id={2} {3} [{4}]: {5}" -f $done, $total, $sw.id, $sw.software_name, $sw.software_version, $r.Error)
                    Notify -name "$($sw.software_name) [$($sw.software_version)]" -itemName "Vulnerabilities" -message ("Error: {0}" -f $r.Error) -category "Error" -state "Faulty" -itemResult "Error"
                    if ($failStreak -ge $maxFailStreak) {
                        $aborted = $true
                        Write-CommonDebug -Context $ctx.Common -Message ("Aborting: {0} consecutive software requests failed (last error: {1})" -f $failStreak, $r.Error)
                        break
                    }
                }
            }

            if (-not $progress) { Start-Sleep -Milliseconds 100 }
        }

        if ($aborted) {
            throw ("Aborted after {0} consecutive failed software requests; device mapping was not written." -f $failStreak)
        }

        $pool.Close()
        $pool.Dispose()
        $pool = $null
        Write-CommonDebug -Context $ctx.Common -Message ("All software processed: {0} ok, {1} failed, {2:N0}s; devices in mapping: {3}" -f ($total - $failed), $failed, $runClock.Elapsed.TotalSeconds, $deviceMap.Count)

        # Get current export data to determine differentials in order to cleanup missing software

        Initialize-LiDrive -context $ctx.Common
        # Determine LI location (folder/query in the LI: provider)
        $location = $ctx.SyncQuery

        Push-Location
        try {
            Set-Location ("LI:\" + $location)
            $left = Get-LiData |
            Select-Object `
                @{n='Name';      e={$_.'SoftwarePackage.Name'}},
                @{n='Version';   e={$_.'SoftwarePackage.Version'}},
                @{n='Publisher'; e={$_.'SoftwarePackage.Publisher'}},
                @{n='Platform'; e={$_.'SoftwarePackage.Platform'}} |
            Sort-Object Name, Version, Publisher, Platform -Unique


            $right = $softwareList | Select-Object `
                @{n='Name';      e={$_.software_name}},
                @{n='Version';   e={$_.software_version}},
                @{n='Publisher'; e={$_.software_publisher}},
                @{n='Platform'; e={$_.software_metadata}}

            # Nur Eintraege, die NUR in $left vorkommen
            $missing = Compare-Object -ReferenceObject $left -DifferenceObject $right `
                    -Property Name,Version,Publisher,Platform -PassThru |
                    Where-Object SideIndicator -eq '<=' |
                    Sort-Object Name,Version,Publisher,Platform -Unique

            if ($missing) {
                foreach ($sw in $missing) {
                    Notify -name "$($sw.Name) [$($sw.Version)]" -itemName "Vulnerabilities" -message "Differentials" -category "Info" -state "Executing" -itemResult "None"
                    NewEntity -name "SoftwarePackage"
                    AddPropertyValue -name "Name"      -value $sw.Name
                    AddPropertyValue -name "Version"   -value $sw.Version
                    AddPropertyValue -name "Publisher" -value $sw.Publisher
                    AddPropertyValue -name "Platform"           -value $sw.Platform
                    AddPropertyValue -name "VulnerabilityScore" -value $null
                    AddPropertyValue -name "SoftwareId"         -value $null
                    AddPropertyValue -name "Vulnerabilities" -value $null
                }
                $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
                $fileName  = "{0}_ci_cleanup.inv" -f $timestamp
                $filePath  = Join-Path $ctx.Common.DataDir $fileName
                Write-CommonDebug -Context $ctx.Common -Message ("Writing INV to {0}" -f $filePath)
                WriteInv -filePath $filePath -version $ctx.Common.Version -useDataNamespace $true
            }
        }
        finally {
            Pop-Location
        }

        # Write device mapping .inv files (streamed; each device's data is released after it was written)
        Notify -name "Vulnerable Device Results" -itemName "-" -message "Writing devices" -category "Info" -state "Executing" -itemResult "None"

        $devicesWritten = 0
        foreach ($device in @($deviceMap.Keys)) {
            $entries   = $deviceMap[$device]
            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
            $safeDev   = New-SafeFileName $device
            $fileName  = "{0}_ci_{1}.inv" -f $timestamp, $safeDev
            $filePath  = Join-Path $ctx.Common.DataDir $fileName

            $inv = Open-CIInv -FilePath $filePath -Version $ctx.Common.Version -Entity 'Device'
            try {
                $w = $inv.Writer
                $w.WriteElementString([string]$ctx.KeyProperty, (ConvertTo-CIXmlText $device))
                for ($e = 0; $e -lt $entries.Count; $e += 2) {
                    $swId  = [string]$entries[$e]
                    foreach ($ciId in $entries[$e + 1]) {
                        $w.WriteStartElement('Vulnerabilities')
                        $w.WriteElementString('SoftwareId', $swId)
                        $w.WriteElementString('Name', $ciId)
                        $w.WriteEndElement()
                    }
                }
                Close-CIInv -Handle $inv
            }
            catch {
                try { Close-CIInv -Handle $inv -Abort } catch {}
                throw
            }
            [void]$deviceMap.Remove($device)
            $devicesWritten++

            Write-CommonDebug -Context $ctx.Common -Message ("Writing INV to {0}" -f $filePath)
            Notify -name "Vulnerability Device Data" -itemName "$($device)" -message ("Written to {0}" -f $filePath) -category "Info" -state "Finished" -itemResult "Ok"
        }
        Notify -name "Vulnerability Device Data" -itemName "-" -message "-" -category "Info" -state "Finished" -itemResult "Ok"
        Notify -name "Vulnerable Device Results" -itemName "-" -message "Writing devices" -category "Info" -state "Finished" -itemResult "Ok"
        Write-CommonDebug -Context $ctx.Common -Message ("Device files written: {0}" -f $devicesWritten)

        $deviceMap.Clear()

        if ($failed -gt 0) {
            throw ("{0} of {1} software entries could not be loaded (see debug log); all other data was written." -f $failed, $total)
        }
    }
    catch {
        Write-CommonDebug -Context $ctx.Common -Message ("ERROR: {0}" -f $_)
        try { Invoke-ErrorNotification -Uri $ctx.ApiUrl -ErrorResponse $_.Exception.Message } catch {}
        Notify -name "CyberInsightApi" -itemName "Script" -message ("Error: {0}" -f $_.Exception.Message) -category "Error" -state "Faulty" -itemResult "Error"
        exit 1
    }
    finally {
        foreach ($job in $running) { try { $job.Ps.Stop() } catch {} ; try { $job.Ps.Dispose() } catch {} }
        if ($pool) { try { $pool.Close(); $pool.Dispose() } catch {} }
        Write-CommonDebug -Context $ctx.Common -Message "GET finished."
    }
}

# Entry
Start-CyberInsightGet -params $parameter
