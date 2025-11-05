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
#>

param (
    [string]$parameter = ""
)

Set-StrictMode -Version Latest

. (Join-Path -Path $PSScriptRoot -ChildPath "..\include\common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "..\include\WebRequest.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "cyberinsight-common.ps1")


# 1) Define rules
#    Pattern: by default uses *substring* match (contains). If you prefer regex, see the comment below.
$patternRules = @(
    @{ Pattern = '.NET Framework Version'; Action = 'MaxVersion' } #, keep only highest version
    #@{ Pattern = 'Some Legacy App'; Action = 'Ignore' }    # ignore all matches
)

# 2) Helper: tolerant version parser (handles 1, 1.2, 1.2.3.4, 2023.10, v1.2.3, etc.)
function Parse-VersionLoose {
    param([string]$v)
    if ([string]::IsNullOrWhiteSpace($v)) { return [int[]](0,0,0,0) }

    # keep digits and dots only
    $clean = $v -replace '[^\d\.]', ''
    if ([string]::IsNullOrWhiteSpace($clean)) { return [int[]](0,0,0,0) }

    $parts = $clean.Split('.', [System.StringSplitOptions]::RemoveEmptyEntries)
    $p0 = if ($parts.Count -ge 1) { [int]($parts[0]) } else { 0 }
    $p1 = if ($parts.Count -ge 2) { [int]($parts[1]) } else { 0 }
    $p2 = if ($parts.Count -ge 3) { [int]($parts[2]) } else { 0 }
    $p3 = if ($parts.Count -ge 4) { [int]($parts[3]) } else { 0 }
    return [int[]]($p0, $p1, $p2, $p3)
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

        Initialize-LiDrive -context $ctx.Common

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

                # 3) Collect everything first: unruled items and rule buckets
                $unruled = New-Object System.Collections.Generic.List[object]
                $buckets = @{} # Key = rule index, Value = List<PSObject>
                
                foreach ($sw in $deviceGroup.Group) {
                    $item = [PSCustomObject]@{
                        software_publisher = if ($sw.Publisher) { $sw.Publisher } else { "" }
                        software_name      = $sw.Name
                        software_version   = if ($sw.Version)   { $sw.Version   } else { "" }
                        software_metadata  = $sw.Platform
                    }

                    # determine whether this item matches a rule
                    $matchedRuleIndex = $null
                    for ($i = 0; $i -lt $patternRules.Count; $i++) {
                        $rule = $patternRules[$i]

                        # --- Substring logic (contains, case-insensitive):
                        if ($item.software_name -like "*$($rule.Pattern)*") {
                            $matchedRuleIndex = $i
                            break
                        }

                        # --- If you prefer regex matching, replace the line above with:
                        # if ($item.software_name -match $rule.Pattern) {
                        #     $matchedRuleIndex = $i
                        #     break
                        # }
                    }

                    if ($null -ne $matchedRuleIndex) {
                        if (-not $buckets.ContainsKey($matchedRuleIndex)) {
                            $buckets[$matchedRuleIndex] = New-Object System.Collections.Generic.List[object]
                        }
                        $buckets[$matchedRuleIndex].Add($item) | Out-Null
                    }
                    else {
                        $unruled.Add($item) | Out-Null
                    }
                }

                # 4) Post-process each bucket according to its rule
                $softwares = New-Object System.Collections.Generic.List[object]

                # pass through items without any rule
                $softwares.AddRange($unruled)

                # decide per rule bucket
                for ($i = 0; $i -lt $patternRules.Count; $i++) {
                    if (-not $buckets.ContainsKey($i)) { continue }

                    $rule  = $patternRules[$i]
                    $items = $buckets[$i]

                    switch ($rule.Action) {
                        'Ignore' {
                            # add nothing
                        }
                        'MaxVersion' {
                            # top by version (desc) then name (desc)
                            $top = $items |
                                Sort-Object -Property `
                                    @{ Expression = {
                                            $v = Parse-VersionLoose $_.software_version   # int[4]
                                            '{0:D9}.{1:D9}.{2:D9}.{3:D9}' -f $v[0], $v[1], $v[2], $v[3]
                                        }; Descending = $true },
                                    @{ Expression = {
                                            $n = $_.software_name
                                            if ($n) { $n.ToLowerInvariant() } else { '' }
                                        }; Descending = $true } |
                                Select-Object -First 1

                            if ($null -ne $top) {
                                $softwares.Add($top) | Out-Null
                            }
                        }
                        default {
                            # unknown action: pass all through
                            $softwares.AddRange($items)
                        }
                    }
                }
               
                $first = $deviceGroup.Group | Select-Object -First 1
                if ($first) {
                    [PSCustomObject]@{
                        device_name = [string]$first.'Device.Name'
                        device_id   = if ($first.'Device.InventoryNumber') { [string]$first.'Device.InventoryNumber' } else { $null }
                        softwares   = $softwares
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
