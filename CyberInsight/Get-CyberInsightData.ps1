#requires -Version 5.1
<#
    File:        Get-CyberInsightData.ps1
    Purpose:     Pull vulnerable software and device mappings from the CyberInsight API,
                 serialize results to LOGINventory .inv files, and emit standard notifications.

    Flow:
      1) Build Common context (encoding, debug, proxy) via New-CommonContext
      2) Build CI-specific context via New-CIContext
      3) Resolve company by name -> companyId
      4) Page through vulnerable software (by dara score)
      5) For each software, page expanded vulnerabilities and their affected devices
      6) Emit .inv files for each software and for device mappings

    Key features:
      * Uses Invoke-CIApi (auth, proxy, retry) and Write-CommonDebug for logging
      * Paginates vulnerable software, vulnerabilities, and devices
      * Writes per-software and per-device .inv files into Common.DataDir
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

# --- File name sanitization ---------------------------------------------------


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

    Write-CommonDebug -Context $ctx.Common -Message ("Effective Config: Url={0}, Company={1}, Language={2}, ProxyActive={3}" -f $ctx.ApiUrl, $ctx.CompanyName, $ctx.Language, $ctx.Common.ProxyConfig.Active)

    try {
        function Get-CICompanyId {
            param([Parameter(Mandatory)]$Context)

            Write-CommonDebug -Context $Context.Common -Message "GET companies…"
            $resp = Invoke-CIApi -Context $Context -Method GET -Path "companies"
            if (-not $resp.IsSuccess) { throw "Companies failed: HTTP $($resp.StatusCode) $($resp.StatusDescription)" }

            $companies = $resp.Body | ConvertFrom-Json
            $company   = $companies | Where-Object { $_.name -eq $Context.CompanyName } | Select-Object -First 1
            if (-not $company) { throw "Company '$($Context.CompanyName)' not found." }

            Write-CommonDebug -Context $Context.Common -Message ("CompanyId = {0}" -f $company.id)
            return $company.id
        }

        function Get-CIDevices {
            param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$CompanyId)

            Write-CommonDebug -Context $Context.Common -Message ("GET devices for company {0}" -f $CompanyId)
            $resp = Invoke-CIApi -Context $Context -Method GET -Path ("companies/{0}/devices" -f $CompanyId)
            if (-not $resp.IsSuccess) { throw "Devices failed: HTTP $($resp.StatusCode) $($resp.StatusDescription)" }
            return ($resp.Body | ConvertFrom-Json)
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
            $resp = Invoke-CIApi -Context $Context -Method GET -Path $path
            if (-not $resp.IsSuccess) { throw "Vulnerable software failed: HTTP $($resp.StatusCode) $($resp.StatusDescription)" }
            return ($resp.Body | ConvertFrom-Json)
        }

        function Get-CISoftwareVulnerabilitiesPage {
            param(
                [Parameter(Mandatory)]$Context,
                [Parameter(Mandatory)][string]$CompanyId,
                [Parameter(Mandatory)][string]$SoftwareId,
                [int]$PageSize = 10,
                [string]$StartAfterCiId = $null,
                [string]$Criticality = $null
            )

            $qs = @("page_size=$PageSize")
            if ($StartAfterCiId) { $qs += "start_after=$StartAfterCiId" }
            if ($Criticality) {
                $qs += ($Criticality -split '\|' | ForEach-Object { "criticality=$($_.Trim())" })
            }
            $path = "companies/{0}/vulnerable_softwares/{1}/expanded_vulnerabilities?{2}" -f $CompanyId, $SoftwareId, ($qs -join '&')

            Write-CommonDebug -Context $Context.Common -Message ("GET vulnerabilities: {0}" -f $path)
            $resp = Invoke-CIApi -Context $Context -Method GET -Path $path
            if (-not $resp.IsSuccess) { throw "Vulnerabilities failed: HTTP $($resp.StatusCode) $($resp.StatusDescription)" }
            return ($resp.Body | ConvertFrom-Json)
        }

        function Get-CISoftwareVulnerabilityDevicesPage {
            param(
                [Parameter(Mandatory)]$Context,
                [Parameter(Mandatory)][string]$CompanyId,
                [Parameter(Mandatory)][string]$SoftwareId,
                [int]$PageSize = 5000,
                [string]$StartAfterCiId = $null,
                [string]$Criticality = $null
            )

            $qs = @("page_size=$PageSize")
            if ($StartAfterCiId) { $qs += "start_after=$StartAfterCiId" }
            if ($Criticality) {
                $qs += ($Criticality -split '\|' | ForEach-Object { "criticality=$($_.Trim())" })
            }
            $path = "companies/{0}/vulnerable_softwares/{1}/vulnerabilities/devices?{2}" -f $CompanyId, $SoftwareId, ($qs -join '&')

            Write-CommonDebug -Context $Context.Common -Message ("GET vulnerabilities: {0}" -f $path)
            $resp = Invoke-CIApi -Context $Context -Method GET -Path $path
            if (-not $resp.IsSuccess) { throw "Vulnerabilities failed: HTTP $($resp.StatusCode) $($resp.StatusDescription)" }
            return ($resp.Body | ConvertFrom-Json)
        }

        # --- Main flow -----------------------------------------------------------

        Notify -name "CyberInsightApi" -itemName "Company" -message ("Searching '{0}'" -f $ctx.CompanyName) -category "Info" -state "Executing" -itemResult "None"
        $companyId = Get-CICompanyId -Context $ctx
        Notify -name "CyberInsightApi" -itemName "Company" -message ("Found {0}" -f $ctx.CompanyName) -category "Info" -state "Finished" -itemResult "Ok"

        # Page vulnerable software
        $softwarePageSize = 100
        $vulnPageSize     = 5000
        $devPageSize      = 5000
        $lastDaraScore    = $null

        $softwareList = New-Object System.Collections.Generic.List[object]

        do {
            $VulnerableSoftware = Get-CIVulnerableSoftwarePage -Context $ctx -CompanyId $companyId -PageSize $softwarePageSize -StartAfterDaraScore $lastDaraScore
            if ($VulnerableSoftware) {
                $VulnerableSoftware = @($VulnerableSoftware)
                foreach ($sw in $VulnerableSoftware) {
                    Notify -name "$($sw.software_name) [$($sw.software_version)]" -itemName "-" -message "-" -category "Info" -itemResult "None" -state "Queued"
                    [void]$softwareList.Add($sw)
                    $lastDaraScore = $sw.dara_score_sum
                }
                if ($VulnerableSoftware.Count -lt $softwarePageSize) {
                    break
                }
            }
            else {
                Notify -name "CyberInsightApi" -itemName "-" -message "No data available yet, please try again later" -category "Error" -state "Faulty" -itemResult "Error"
                exit 1
            }
            
        } while ($true)

        # Mapping: device -> list of (software_id, ci_id)
        $deviceMap = @{}
        foreach ($sw in $softwareList) {
            Notify -name "$($sw.software_name) [$($sw.software_version)]" -itemName "Vulnerabilities" -message "Loading" -category "Info" -state "Executing" -itemResult "None"

            NewEntity -name "SoftwarePackage"
            AddPropertyValue -name "Name"               -value $sw.software_name
            AddPropertyValue -name "Version"            -value $sw.software_version
            AddPropertyValue -name "Publisher"          -value $sw.software_publisher
            AddPropertyValue -name "Platform"           -value $sw.software_metadata
            AddPropertyValue -name "VulnerabilityScore" -value ([math]::Round($sw.dara_score_sum * 10, 2, [System.MidpointRounding]::AwayFromZero))

            AddPropertyValue -name "SoftwareId"         -value $sw.id

            $startAfterCi = $null
            do {
                $vulns = Get-CISoftwareVulnerabilitiesPage -Context $ctx -CompanyId $companyId -SoftwareId $sw.id -PageSize $vulnPageSize -StartAfterCiId $startAfterCi -Criticality $ctx.Criticality
                foreach ($v in $vulns) {
                    AddPropertyValue -name "Vulnerabilities.Name"                  -value $v.ci_id
                    AddPropertyValue -name "Vulnerabilities.Score"                 -value ([math]::Round($v.dara_score * 10, 2, [System.MidpointRounding]::AwayFromZero))
                    AddPropertyValue -name "Vulnerabilities.Description"           -value $v.description
                    AddPropertyValue -name "Vulnerabilities.AttackVector"          -value $v.attack_vector
                    AddPropertyValue -name "Vulnerabilities.AttackComplexity"      -value $v.attack_complexity
                    AddPropertyValue -name "Vulnerabilities.PrivilegesRequired"    -value $v.privileges_required
                    AddPropertyValue -name "Vulnerabilities.UserInteraction"       -value $v.user_interaction
                    AddPropertyValue -name "Vulnerabilities.Scope"                 -value $v.scope
                    AddPropertyValue -name "Vulnerabilities.ConfidentialityImpact" -value $v.confidentiality
                    AddPropertyValue -name "Vulnerabilities.IntegrityImpact"       -value $v.integrity
                    AddPropertyValue -name "Vulnerabilities.AvailabilityImpact"    -value $v.availability
                    AddPropertyValue -name "Vulnerabilities.IsExploitable"         -value $v.is_exploitable
                    AddPropertyValue -name "Vulnerabilities.SoftwareId"            -value $sw.id
                }
                $startAfterCi = if (@($vulns).Count -gt 0) { $vulns[-1].ci_id } else { $null }
            } while (@($vulns).Count -ge $vulnPageSize)

            # Page affected devices
            $startDevAfterCi = $null
            do {
                $vCiDevs = Get-CISoftwareVulnerabilityDevicesPage -Context $ctx -CompanyId $companyId -SoftwareId $sw.id -PageSize $devPageSize -StartAfterCiId $startDevAfterCi -Criticality $ctx.Criticality
                foreach ($vCi in $vCiDevs) {
                    foreach ($d in $vCi.devices) {
                        # Device key: prefer Name when KeyProperty=Name, else use server id
                        $deviceKey = if ($ctx.KeyProperty -eq "Name") { [string]$d.name } else { $d.id }
                        if (-not $deviceMap.ContainsKey($deviceKey)) { $deviceMap[$deviceKey] = New-Object System.Collections.Generic.List[object] }
                        [void]$deviceMap[$deviceKey].Add([PSCustomObject]@{ software_id = $sw.id; ci_id = $vCi.ci_id })
                    }
                }
                $startDevAfterCi = if (@($vCiDevs).Count -gt 0) { $vCiDevs[-1].ci_id } else { $null }
            } while (@($vCiDevs).Count -ge $devPageSize)

            # Write .inv for this software (sanitize name/version)
            $timestamp   = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
            $safeName    = New-SafeFileName $sw.software_name
            $safeVersion = New-SafeFileName $sw.software_version
            $fileName    = "{0}_ci_{1}_{2}.inv" -f $timestamp, $safeName, $safeVersion
            $filePath    = Join-Path $ctx.Common.DataDir $fileName

            Write-CommonDebug -Context $ctx.Common -Message ("Writing INV to {0}" -f $filePath)
            Notify -name "Vulnerability Data" -itemName "-" -message ("Write to {0}" -f $filePath) -category "Info" -state "Executing" -itemResult "None"
            WriteInv -filePath $filePath -version $ctx.Common.Version
            Notify -name "Vulnerability Data" -itemName "-" -message ("Written to {0}" -f $filePath) -category "Info" -state "Finished" -itemResult "Ok"

            Notify -name "$($sw.software_name) [$($sw.software_version)]" -itemName "Vulnerabilities" -message "Done" -category "Info" -state "Finished" -itemResult "Ok"
        }

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

            # Nur Einträge, die NUR in $left vorkommen
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

        # Write device mapping .inv files (sanitize device key)
        Notify -name "Vulnerable Device Results" -itemName "-" -message "Writing devices" -category "Info" -state "Executing" -itemResult "None"

        foreach ($device in $deviceMap.Keys) {
            NewEntity -name "Device"
            AddPropertyValue -name $ctx.KeyProperty -value $device
            foreach ($tuple in $deviceMap[$device]) {
                AddPropertyValue -name "Vulnerabilities.SoftwareId" -value $tuple.software_id
                AddPropertyValue -name "Vulnerabilities.Name"       -value $tuple.ci_id
            }

            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
            $safeDev   = New-SafeFileName $device
            $fileName  = "{0}_ci_{1}.inv" -f $timestamp, $safeDev
            $filePath  = Join-Path $ctx.Common.DataDir $fileName

            Write-CommonDebug -Context $ctx.Common -Message ("Writing INV to {0}" -f $filePath)
            WriteInv -filePath $filePath -version $ctx.Common.Version
            Notify -name "Vulnerability Device Data" -itemName "$($device)" -message ("Written to {0}" -f $filePath) -category "Info" -state "Finished" -itemResult "Ok"
        }
        Notify -name "Vulnerability Device Data" -itemName "-" -message "-" -category "Info" -state "Finished" -itemResult "Ok"
        Notify -name "Vulnerable Device Results" -itemName "-" -message "Writing devices" -category "Info" -state "Finished" -itemResult "Ok"

        $deviceMap.Clear()
    }
    catch {
        Write-CommonDebug -Context $ctx.Common -Message ("ERROR: {0}" -f $_)
        try { Invoke-ErrorNotification -Uri $ctx.ApiUrl -ErrorResponse $_.Exception.Message } catch {}
        Notify -name "CyberInsightApi" -itemName "Script" -message ("Error: {0}" -f $_.Exception.Message) -category "Error" -state "Faulty" -itemResult "Error"
        exit 1
    }
    finally {
        Write-CommonDebug -Context $ctx.Common -Message "GET finished."
    }
}

# Entry
Start-CyberInsightGet -params $parameter
