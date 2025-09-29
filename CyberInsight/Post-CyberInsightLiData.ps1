#requires -Version 5.1
<#
    File:        Post-CyberInsightLiData.ps1
    Purpose:     Read device/software data from LOGINventory (LI: drive), transform to the
                 CyberInsight ThreatFinder input format, and POST it to the API.

    Flow:
      1) Build Common context (encoding, debug, proxy) via New-CommonContext
      2) Build CI-specific context via New-CIContext
      3) Initialize LOGINventory PSDrive (LI:)
      4) Query LI data (location from ExportQuery or a default path)
      5) Group by the configured device key property (default "Name")
      6) Build the request JSON and POST to /threat-finder/submit

    Key features:
      * Respects proxy and Accept-Language from Common/CI context
      * Logs via Write-CommonDebug when DebugFile is set
      * Emits standardized Notify() events for external log collectors

    Notes:
      - Devices with more than one matching row in the LI export are included, exactly as in the original logic.
      - The working directory is restored after accessing the LI: drive (Push/Pop-Location).

    Requirements:
      - include\common.ps1           (context building, helpers, Notify, etc.)
      - include\WebRequest.ps1       (Invoke-LoginWebRequest, URL normalization)
      - cyberinsight-common.ps1      (CI context & API helpers)
      - LOGINventory PowerShell snap-ins available on the host

    Last Updated: 2025-09-26
#>

param (
    [string]$parameter = ""
)

Set-StrictMode -Version Latest

. (Join-Path -Path $PSScriptRoot -ChildPath "..\include\common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "..\include\WebRequest.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "cyberinsight-common.ps1")

function Initialize-LiDrive {
    <#
    .SYNOPSIS
        Ensures the LOGINventory PSDrive (LI:) is available.
    .PARAMETER installPath
        Optional install path passed to LOGINventory snap-ins/app-domain.
    #>
    [CmdletBinding()]
    param([string]$installPath = "")
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

function Start-CyberInsightPost {
    <#
    .SYNOPSIS
        Collects LI data, builds the ThreatFinder input JSON, and POSTs it to CyberInsight.
    .PARAMETER p
        Encoded parameter blob (same format used by New-CommonContext).
    #>
    [CmdletBinding()]
    param([string]$p = "")

    # 1) Build Common context (encoding, debug & proxy)
    $common = New-CommonContext -Parameters $p -StartLabel 'CI'
    # 2) Build CI domain context
    $ctx = New-CIContext -Common $common

    try {
        Write-CommonDebug -Context $ctx.Common -Message "Collecting data from LOGINventory interface..."

        # Determine LI install path; default to PowerShell home folder if not set
        $installPath = $ctx.Common.LiInstallPath
        if ([string]::IsNullOrWhiteSpace($installPath)) {
            $installPath = Split-Path -Path $PSHome
        } else {
            $installPath = $installPath.Trim()
        }
        Initialize-LiDrive -installPath $installPath

        # Determine LI location (folder/query in the LI: provider)
        $location = $ctx.ExportQuery

        Push-Location
        try {
            Set-Location ("LI:\" + $location)

            if ($null -eq $ctx.KeyProperty) { $ctx.KeyProperty = "Name" }
            $Property = "Device.$($ctx.KeyProperty)"

            # Group LI data by the configured device key
            $devicesGrouped = Get-LiData | Group-Object -Property { $_.PSObject.Properties[$Property].Value }

            Notify -name "Creating JSON object" -itemName "Preparing data" -message "Getting assets" -category "Info" -state "Calculating"

            # Build per-device objects (retain original condition: only groups with Count > 1)
            $deviceObjects = foreach ($deviceGroup in $devicesGrouped) {
                if ($deviceGroup.Count -gt 1) {
                    $first = $deviceGroup.Group[0]
                    # Build the per-device software list from the grouped rows
                    [PSCustomObject]@{
                        device_name = [string]$first.'Device.Name'
                        device_id   = if ($null -ne $first.'Device.InventoryNumber') { [string]$first.'Device.InventoryNumber' } else { $null }
                        softwares   = $deviceGroup.Group | ForEach-Object {
                            [PSCustomObject]@{
                                software_publisher = if ($_.Publisher) { $_.Publisher } else { "" }
                                software_name      = $_.Name
                                software_version   = if ($_.Version) { $_.Version } else { "" }
                                software_metadata  = $_.Platform
                            }
                        }
                    }
                    Notify -name $deviceGroup.Name -itemName "Generation" -message $deviceGroup.Name -category "Info" -itemResult "Ok" -state "Finished"
                }
            }

            # Compose request body
            $jsonBodyObject = [PSCustomObject]@{
                company_name = $ctx.CompanyName
                devices      = $deviceObjects
            }

            # Robust: ensure we produce a JSON ARRAY payload (PS5 compatible)
            $jsonBody = ConvertTo-Json -InputObject @($jsonBodyObject) -Depth 5 -Compress

            Notify -name "Creating JSON object" -itemName "Preparing data" -message "Getting assets" -category "Info" -itemResult "Ok" -state "Finished"
        }
        finally {
            Pop-Location
        }

        # POST to ThreatFinder
        $resp = Invoke-CIApi -Context $ctx `
                 -Method POST `
                 -Path "threat-finder/submit" `
                 -Body $jsonBody

        if (-not $resp.IsSuccess) {
            throw "POST failed: HTTP $($resp.StatusCode) $($resp.StatusDescription)"
        }

        Write-CommonDebug -Context $ctx.Common -Message "POST done."
        Notify -name "CyberInsight API" -itemName "Server" -message "POST request successful. The data is now being examined for vulnerabilities in ThreatFinder." -category "Info" -itemResult "Ok" -state "Finished"
    }
    catch {
        Write-CommonDebug -Context $ctx.Common -Message ("ERROR: {0}" -f $_)
        try {
            Invoke-ErrorNotification -Uri ($ctx.ApiUrl.TrimEnd('/') + "/threat-finder/submit") -ErrorResponse ([pscustomobject]@{ code="POST_FAILED"; message=$_.ToString() })
        } catch {}
        throw
    }
    finally {
        Write-CommonDebug -Context $ctx.Common -Message "POST finished."
    }
}

# Entry
Start-CyberInsightPost -p $parameter
