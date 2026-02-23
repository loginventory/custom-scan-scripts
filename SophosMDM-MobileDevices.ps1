<#
.SYNOPSIS
A script to collect information about mobile devices from Sophos MDM.

.DESCRIPTION
This script uses the Sophos Mobile API to retrieve information about mobile devices.
The collected information is written to an .inv file for further processing by the Data Service.

.AUTHOR
Schmidt's LOGIN GmbH

.VERSION
1.0.0

.LICENSE
This script is licensed under the MIT License. Full license information can be found at [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

.NOTES
In order to use this script, you need to create an API key. In order to create an API Key, you have to login to Sophos Central Admin portal as a Super Admin.

Navigate to Settings -> API Connections and create a new API Client. Note down the Client ID and Client Secret, you will need them to authenticate your API calls.

The script requires the following parameters to execute correctly:

.PARAMETER
You can use these credentials in the RemoteScanner under script-based inventory in the Parameters section, or directly here:
- clientId (e.g. "1234567890abcdef1234567890abcdef")
- clientSecret (e.g. "1234567890abcdef1234567890abcdef")

When specifying the values in the Remote Scanner, quotation marks can be omitted.
#>

# Default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)
. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")

$ctx = New-CommonContext -Parameters $parameter -StartLabel 'STARTER'
# End of default header ----------------------------------------------------------------------


# ------------ CONFIGURATION -----------------

$clientId = $ctx.UserParameters.clientId  # Client ID
$clientSecret = $ctx.UserParameters.clientSecret  # Client Secret

# How many devices per page in the list call
$pageSize     = 100     

if (-not $clientId -or -not $clientSecret) {
    throw "ClientId or ClientSecret is not set."
}

# ------------ 1. GET ACCESS TOKEN ---------
$tokenUri = "https://id.sophos.com/api/v2/oauth2/token"

$tokenBody = @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSecret
    scope         = "token"
}
Write-CommonDebug -Context $ctx -Message "Fetching Access Token..."

$tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUri `
    -Body $tokenBody `
    -ContentType "application/x-www-form-urlencoded"

$accessToken = $tokenResponse.access_token

if (-not $accessToken) {    
    Notify -name "Error" -itemName "Error retrieving Access Token" -message "Check if client ID and Secret are correct and if https://id.sophos.com/api/v2/oauth2/token can be reached" -category "Error" -state "Faulty" -ItemResult "Error"
    throw "No access_token received in response. Response: $($tokenResponse | ConvertTo-Json -Depth 5)"
}

Write-CommonDebug -Context $ctx -Message "Access Token successfully obtained."

$baseHeaders = @{
    "Authorization" = "Bearer $accessToken"
    "Accept"        = "application/json"
}

# ------------ 2. WHOAMI: TENANT & REGION ----
$whoamiUri = "https://api.central.sophos.com/whoami/v1"
Write-CommonDebug -Context $ctx -Message "Calling whoami endpoint..."

$whoami = Invoke-RestMethod -Method Get -Uri $whoamiUri -Headers $baseHeaders

$tenantId   = $whoami.id
$dataRegion = $whoami.apiHosts.dataRegion.TrimEnd('/')

Write-CommonDebug -Context $ctx -Message "Tenant-ID : $tenantId"
Write-CommonDebug -Context $ctx -Message "DataRegion: $dataRegion"

if (-not $tenantId -or -not $dataRegion) {
    Notify -name "Error" -itemName "Error calling whoami endpoint" -message "Could not determine Tenant-ID or DataRegion." -category "Error" -state "Faulty" -ItemResult "Error"
    throw "Could not determine Tenant-ID or DataRegion. Response: $($whoami | ConvertTo-Json -Depth 5)"
}

$mobileHeaders = $baseHeaders.Clone()
$mobileHeaders["X-Tenant-ID"] = $tenantId

# ------------ 3. GET ALL DEVICE IDs ------

Write-CommonDebug -Context $ctx -Message "Retrieving list of all mobile devices (IDs)..."

$allDeviceIds = @()

$page       = 1
$pagesTotal = $null

do {
    $query   = "page=$page&pageSize=$pageSize&pageTotal=true"
    $listUri = "$dataRegion/mobile/v1/devices?$query"

    Write-CommonDebug -Context $ctx -Message "Fetching page $page $listUri"

    $resp = Invoke-RestMethod -Method Get -Uri $listUri -Headers $mobileHeaders

    if (-not $resp.items) {
        Write-CommonDebug -Context $ctx -Message "Page ${page}: no items -> breaking list loop."
        break
    }

    # pages = @{ current = 1; size = 100; total = 1; items = 49; maxSize = 500 }
    if (-not $pagesTotal -and $resp.pages -and $resp.pages.total) {
        $pagesTotal = [int]$resp.pages.total
        Write-CommonDebug -Context $ctx -Message "Total pages according to API: $pagesTotal"
    }

    $resp.items | ForEach-Object { $allDeviceIds += $_.id }

    $itemsOnPage = $resp.items.Count
    Write-CommonDebug -Context $ctx -Message "Page ${page}: $itemsOnPage device(s)."

    $page++

} while ($pagesTotal -and $page -le $pagesTotal)

Notify -name "Information" -itemName "Evaluation" -itemResult "None" "Number of devices found: $($allDeviceIds.Count)" -category "Info" -state "Detecting"

if ($allDeviceIds.Count -eq 0) {
    Write-CommonDebug -Context $ctx -Message "No devices found – nothing to retrieve details for."
    return
}

# ------------ 4. FOR EACH ID: GET /devices/{id} ------

Write-CommonDebug -Context $ctx -Message "Fetching device details for all devices..."

$fullDevices = @()
$index       = 0
$total       = $allDeviceIds.Count

foreach ($id in $allDeviceIds) {
    $index++
    $detailUri = "$dataRegion/mobile/v1/devices/${id}?view=full"

    Notify -name "Getting Data" -itemName "Getting Data" -itemResult "None" "[$index/$total] - Getting device details" -category "Info" -state "Detecting"
    Write-CommonDebug -Context $ctx -Message ("[{0}/{1}] GET {2}" -f $index, $total, $id)

    try {
        $detail = Invoke-RestMethod -Method Get -Uri $detailUri -Headers $mobileHeaders

        # Retrieve serial number separately as it is not included in standard details
        $serialNumber = $null
        # Slight delay to avoid rate limiting
        Start-Sleep -Milliseconds 100
        try {
            $serialUri = "$dataRegion/mobile/v1/devices/${id}/properties?devicePropertyKey=device.serial-number"
            $serialResponse = Invoke-RestMethod -Method Get -Uri $serialUri -Headers $mobileHeaders

            if ($serialResponse.items) {
                $serialItem = $serialResponse.items | Select-Object -First 1
                $serialNumber = $serialItem.value
            }
        }
        catch {
            Write-CommonDebug -Context $ctx -Message "   -> Serial number for device ${id} could not be retrieved: $($_.Exception.Message)"

            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                Write-CommonDebug -Context $ctx -Message "      Error details: $($_.ErrorDetails.Message)"
            }
        }

        if ($serialNumber) {
            $detail | Add-Member -NotePropertyName serialNumber -NotePropertyValue $serialNumber -Force
        }

        $fullDevices += $detail
    }
    catch {
        Write-CommonDebug -Context $ctx -Message "   -> Error retrieving device ${id}: $($_.Exception.Message)"

        # Try to read error message from response body if available
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            Write-CommonDebug -Context $ctx -Message "      Error details: $($_.ErrorDetails.Message)"
        }
        continue
    }

    # Slight delay to avoid rate limiting
    Start-Sleep -Milliseconds 100
}

Write-CommonDebug -Context $ctx -Message "Number of successfully loaded detail objects: $($fullDevices.Count)"

# ------------ 5. CREATE .inv FILE ------------

# Insert data
foreach($device in $fulldevices) {
    # Create new device
    NewEntity -name "Device"

    # Device name
    AddPropertyValue -name "Name"  -value $device.name
    
    # Reactivate archived assets
    AddPropertyValue -name "Archived" -value ""

    # Device serial number
    AddPropertyValue -name "SerialNumber" -value $device.serialNumber

    AddPropertyValue -name "Created{Editable:true}" -value $device.createdAt

    # Make sure that the Asset can be edited afterwards using the Asset Editor in LOGINventory
    AddPropertyValue -name "Author" -value "Asset Editor"
    AddPropertyValue -name "Discriminator" -value "20"

    # Convert email to domain\user format

    $ownerName = ""
    if (-not [string]::IsNullOrWhiteSpace($device.email)) {
        $emailParts = $device.email -split '@'
        if ($emailParts.Length -eq 2) {
            $ownerName = "$($emailParts[1])\$($emailParts[0])"
        }
    }

    AddPropertyValue -name "Owner.Name" -value $ownerName

    # Device type
    AddPropertyValue -name "DeviceInfo.ChassisType" -value "Mobile"

    AddPropertyValue -name "DeviceInfo.Description" -value $device.description

    # Operating system, version and installation date
    $osName = ""
    $osVersion = ""
    $osArray= if (-not [string]::IsNullOrWhiteSpace($device.os.name)) {
        ($device.os.name.Trim() -split '\s+', 2)
    } else {
        ""
    }
    if ($osArray.Length -ge 2) {
        $osName = $osArray[0]
        $osVersion = $osArray[1]
    } elseif ($osArray.Length -eq 1) {
        $osName = $osArray[0]
    }
    # Writing the full OS name (e.g. "iOS 16.4") as "OperatingSystem.Name"
    AddPropertyValue -name "OperatingSystem.Name" -value $device.os.name
    AddPropertyValue -name "OperatingSystem.Version" -value $osVersion
    AddPropertyValue -name "OperatingSystem.Platform" -value $device.os.platform

    AddPropertyValue -name "Custom.LastSeenAt" -value $device.lastSeenAt
    AddPropertyValue -name "Custom.UpdatedAt" -value $device.updatedAt
    AddPropertyValue -name "Custom.IXMAppLastSeenAt" -value $device.ixmAppLastSeenAt
    AddPropertyValue -name "Custom.OwnershipType" -value $device.ownershipType
    AddPropertyValue -name "Custom.ManagementType" -value $device.managementType
    AddPropertyValue -name "Custom.ManagedState" -value $device.managedState
    AddPropertyValue -name "Custom.HealthState" -value $device.healthState.state
    AddPropertyValue -name "Custom.HealthStatusMode" -value $device.healthState.mode
    AddPropertyValue -name "Custom.Compliant" -value $device.compliance.compliant
    AddPropertyValue -name "Custom.ComplianceSeverity" -value $device.compliance.severity
    AddPropertyValue -name "Custom.DeviceGroup" -value $device.deviceGroup.name
    AddPropertyValue -name "Custom.DeviceGroupId" -value $device.deviceGroup.id

    AddPropertyValue -name "LastInventory.Timestamp" -value $device.lastSeenAt

    # Device manufacturer and model
    $manufacturer = ""
    $manufacturer = if (-not [string]::IsNullOrWhiteSpace($device.modelName)) {
        ($device.modelName.Trim() -split '\s+', 2)[0]
    } else {
        ""
    }
    AddPropertyValue -name "HardwareProduct.Manufacturer{Editable:true}" -value $manufacturer
    AddPropertyValue -name "HardwareProduct.Name" -value $device.modelName

    # Device phone number
    AddPropertyValue -name "MobileDeviceInfo.PhoneNumber" -value $device.phoneNumber
    AddPropertyValue -name "MobileDeviceInfo.DeviceId" -value $device.id

    # Define file name and file path
    $fileName = "$($ctx.TimeStamp)@$($device.name -replace '[\\/:*?"<>|]', '').inv"
    $filePath = "$($ctx.DataDir)\$fileName"

    # Create inventory file and save to data directory
    WriteInv -filePath "$filePath" -version $ctx.Version

    # Notify LOGINventory Job Monitor
    Notify -name $device.name -itemName "Writing Data" -message $device.name -category "Info" -state "Finished" -ItemResult "Ok"
}
