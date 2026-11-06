<# LI-MANIFEST
{
  "schema": 1,
  "id": "intune-devices",
  "version": "3.0.0",
  "tier": "login",
  "maintainer": "Schmidt's LOGIN GmbH",
  "title": { "de": "Microsoft Intune Geräte", "en": "Microsoft Intune devices" },
  "summary": {
    "de": "Liest in Intune verwaltete Geräte über Microsoft Graph und legt sie als Assets an, wahlweise nur mobile Geräte.",
    "en": "Reads devices managed by Intune via Microsoft Graph and creates them as assets, optionally mobile devices only."
  },
  "category": "mdm",
  "creates": ["Assets"],
  "engine": "pwsh",
  "requires": {
    "modules": [],
    "permissions": [
      "Microsoft Graph: DeviceManagementManagedDevices.Read.All (Application)",
      "Microsoft Graph: User.Read.All (Application, optional: device owner)"
    ]
  },
  "endpoints": ["login.microsoftonline.com", "graph.microsoft.com"],
  "testRun": true,
  "docs": {
    "de": "https://github.com/loginventory/custom-scan-agents/blob/main/catalog/IntuneDevices.ps1",
    "en": "https://github.com/loginventory/custom-scan-agents/blob/main/catalog/IntuneDevices.ps1"
  },
  "parameters": [
    {
      "name": "tenantId", "type": "string", "required": true,
      "label": { "de": "Tenant-ID", "en": "Tenant ID" }
    },
    {
      "name": "clientId", "type": "string", "required": true,
      "label": { "de": "Client-ID der App-Registrierung", "en": "App registration client ID" }
    },
    {
      "name": "clientSecret", "type": "secret", "required": true,
      "label": { "de": "Client-Secret", "en": "Client secret" }
    },
    {
      "name": "scanOnlyMobileDevices", "type": "bool", "default": false,
      "label": { "de": "Nur mobile Geräte (iOS, Android)", "en": "Mobile devices only (iOS, Android)" }
    }
  ]
}
#>
<#
.SYNOPSIS
Ein Skript zur Erfassung von Microsoft Intune Geräteinformationen über Microsoft Graph.

.DESCRIPTION
Dieses Skript ruft über die Microsoft Graph REST API Informationen über Geräte in Microsoft Intune ab.
Die gesammelten Informationen werden zur Weiterverarbeitung durch den Data Service in eine .inv Datei geschrieben.

Das Skript benötigt keine zusätzlichen PowerShell-Module (das Modul Microsoft.Graph wird nicht mehr verwendet).
Die Anfragen laufen über include\WebRequest.ps1 und berücksichtigen damit die Proxy-Einstellungen von LOGINventory.

.AUTHORS
Tjark-sys & LOGINVENTORY Team

.VERSION
3.0.0

.LICENSE
Dieses Skript ist unter der MIT-Lizenz lizenziert. Vollständige Lizenzinformationen finden Sie unter [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

.NOTES
Im Ordner "include" neben dem Skript müssen die Dateien common.ps1 und WebRequest.ps1 liegen.

Die verwendete App Registration benötigt folgende Microsoft Graph Berechtigungen vom Typ "Application permissions",
jeweils mit "Admin Consent granted" (in der App Registration unter "API Permissions"):
- DeviceManagementManagedDevices.Read.All    Lesen der in Intune verwalteten Geräte (erforderlich)
- User.Read.All                              Ermitteln des Besitzers (Domäne\Anmeldename) eines Geräts

Fehlt DeviceManagementManagedDevices.Read.All, bricht das Skript mit einem entsprechenden Fehler im Job Monitor ab.
Fehlt User.Read.All, werden die Geräte ohne Besitzer übernommen und im Job Monitor erscheint ein Hinweis.

.PARAMETER
Diese Zugangsdaten können Sie im RemoteScanner in der Skriptbasierten Inventarisierung unter Parameter, oder hier direkt verwenden.
- tenantId
- clientId
- clientSecret
- scanOnlyMobileDevices    Optionaler Parameter, der angibt, ob nur mobile Geräte (iOS und Android) gescannt werden sollen. Standardmäßig werden alle Geräte gescannt. Mögliche Ausprägungen: "true" oder "false".

#>

#default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)
. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "include\WebRequest.ps1")

$ctx = New-CommonContext -Parameters $parameter -StartLabel 'Intune'
#end of default header ----------------------------------------------------------------------


# --- Microsoft Graph helpers ------------------------------------------------------------

function Get-GraphAccessToken {
    <#
    .SYNOPSIS
        Requests an app-only token (client credentials). Returns @{ AccessToken; Error }.
    #>
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)

    $tokenUri = "https://login.microsoftonline.com/$([uri]::EscapeDataString($TenantId))/oauth2/v2.0/token"
    $body = 'grant_type=client_credentials' +
            '&client_id=' + [uri]::EscapeDataString($ClientId) +
            '&client_secret=' + [uri]::EscapeDataString($ClientSecret) +
            '&scope=' + [uri]::EscapeDataString('https://graph.microsoft.com/.default')
    $headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded' }

    $resp = Invoke-LoginWebRequest -Method POST -Uri $tokenUri -Headers $headers -Body $body -ProxyConfig $ctx.ProxyConfig -DebugFile $ctx.DebugFile

    $json = $null
    try { $json = $resp.Body | ConvertFrom-Json -ErrorAction Stop } catch { }

    if ($resp.IsSuccess -and $json -and $json.access_token) {
        return @{ AccessToken = [string]$json.access_token; Error = $null }
    }

    # error_description holds the AADSTS text; its first line is the readable part (Trace ID etc. follow).
    $detail = $null
    if ($json -and $json.error_description) { $detail = ([string]$json.error_description -split "`r?`n")[0] }
    elseif ($json -and $json.error) { $detail = [string]$json.error }
    else { $detail = [string]$resp.StatusDescription }
    return @{ AccessToken = $null; Error = "HTTP $($resp.StatusCode): $detail" }
}

function New-GraphError {
    <#
    .SYNOPSIS
        Builds an exception from a failed Graph response (Graph's error.message, permission hint for 403).
        The HTTP status is available as $_.Exception.Data['StatusCode'].
    #>
    param($Response, [string]$Permission)

    $status = 0
    if ($Response.StatusCode) { $status = [int]$Response.StatusCode }
    $detail = $null
    try {
        $err = $Response.Body | ConvertFrom-Json -ErrorAction Stop
        if ($err.error.message) { $detail = [string]$err.error.message }
    } catch { }
    if (-not $detail) { $detail = [string]$Response.StatusDescription }

    $msg = "Microsoft Graph request failed (HTTP $status): $detail"
    if ($status -eq 403 -and $Permission) {
        $msg += " - The app registration probably lacks the application permission '$Permission' (admin consent required)."
    }
    $ex = New-Object System.Exception($msg)
    $ex.Data['StatusCode'] = $status
    return $ex
}

function Invoke-GraphGet {
    <#
    .SYNOPSIS
        GET request against Graph; retries HTTP 429 (Retry-After), throws on any other failure.
    #>
    param([string]$Uri, [hashtable]$Headers, [string]$Permission)

    $maxAttempts = 5
    for ($attempt = 1; ; $attempt++) {
        $resp = Invoke-LoginWebRequest -Method GET -Uri $Uri -Headers $Headers -ProxyConfig $ctx.ProxyConfig -DebugFile $ctx.DebugFile
        if ($resp.IsSuccess) {
            return ($resp.Body | ConvertFrom-Json)
        }

        if ([int]$resp.StatusCode -eq 429 -and $attempt -lt $maxAttempts) {
            # Windows PowerShell returns no headers for failed requests; fall back to 2, 4, 8, 16 seconds.
            $delay = [math]::Pow(2, $attempt)
            if ($resp.Headers) {
                foreach ($key in @($resp.Headers.Keys)) {
                    if ($key -ieq 'Retry-After') {
                        $seconds = 0
                        if ([int]::TryParse([string](@($resp.Headers[$key])[0]), [ref]$seconds) -and $seconds -gt 0) { $delay = $seconds }
                    }
                }
            }
            Write-CommonDebug -Context $ctx -Message "Graph throttled (HTTP 429), attempt $attempt/$maxAttempts, waiting $delay s"
            Start-Sleep -Seconds $delay
            continue
        }

        throw (New-GraphError -Response $resp -Permission $Permission)
    }
}

function Get-GraphCollection {
    <#
    .SYNOPSIS
        Returns all items of a Graph collection, following @odata.nextLink.
    #>
    param([string]$Uri, [hashtable]$Headers, [string]$Permission)

    $next = $Uri
    while ($next) {
        $page = Invoke-GraphGet -Uri $next -Headers $Headers -Permission $Permission
        foreach ($item in @($page.value)) {
            if ($null -ne $item) { $item }
        }
        $next = $page.'@odata.nextLink'
    }
}

function ConvertTo-GraphModuleDateString {
    <#
    .SYNOPSIS
        Formats a Graph date like the Microsoft.Graph module did (UTC, "MM/dd/yyyy HH:mm:ss", invariant culture),
        so values already stored in LOGINventory do not change.
    .DESCRIPTION
        PowerShell 7 ConvertFrom-Json returns [datetime], Windows PowerShell 5.1 returns the ISO string.
    #>
    param($Value)

    if ($null -eq $Value) { return '' }
    $dt = $null
    if ($Value -is [datetime]) {
        $dt = $Value
    }
    else {
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return '' }
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $text }
        $dt = $parsed
    }
    if ($dt.Kind -eq [System.DateTimeKind]::Local) { $dt = $dt.ToUniversalTime() }
    return $dt.ToString('MM/dd/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-OwnerMap {
    <#
    .SYNOPSIS
        Looks up users by id. Returns @{ Owners = hashtable id -> user (id, onPremisesDomainName,
        onPremisesSamAccountName); FailedCount = number of users whose lookup failed }.
        Users that no longer exist are simply missing from Owners.
    .DESCRIPTION
        Uses "id in (...)" with 15 ids per request (Graph limit). If Graph rejects the filter (HTTP 400),
        falls back to one request per user.
        A failed request only loses the owners it covers; owners found so far are kept.
        HTTP 403 (permission missing) is thrown, because every further request would fail the same way.
    #>
    param([string[]]$UserIds, [hashtable]$Headers)

    $map = @{}
    $failed = 0
    $select = '$select=id,onPremisesDomainName,onPremisesSamAccountName'
    $useFilter = $true
    $chunkSize = 15

    for ($i = 0; $i -lt $UserIds.Count; $i += $chunkSize) {
        $chunk = @($UserIds[$i..([math]::Min($i + $chunkSize, $UserIds.Count) - 1)])

        if ($useFilter) {
            $idList = ($chunk | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
            $uri = 'https://graph.microsoft.com/v1.0/users?$filter=id in (' + $idList + ')&' + $select
            try {
                foreach ($user in (Get-GraphCollection -Uri $uri -Headers $Headers -Permission 'User.Read.All')) {
                    $map[[string]$user.id] = $user
                }
                continue
            }
            catch {
                $status = $_.Exception.Data['StatusCode']
                if ($status -eq 403) { throw }
                if ($status -ne 400) {
                    Write-CommonDebug -Context $ctx -Message "Owner lookup for $($chunk.Count) users failed: $($_.Exception.Message)"
                    $failed += $chunk.Count
                    continue
                }
                Write-CommonDebug -Context $ctx -Message "User filter rejected ($($_.Exception.Message)), falling back to one request per user"
                $useFilter = $false
            }
        }

        foreach ($id in $chunk) {
            $uri = 'https://graph.microsoft.com/v1.0/users/' + [uri]::EscapeDataString($id) + '?' + $select
            try {
                $map[$id] = Invoke-GraphGet -Uri $uri -Headers $Headers -Permission 'User.Read.All'
            }
            catch {
                $status = $_.Exception.Data['StatusCode']
                if ($status -eq 403) { throw }
                # Like before: users that no longer exist (or invalid ids) are ignored.
                if ($status -ne 404 -and $status -ne 400) {
                    Write-CommonDebug -Context $ctx -Message "Owner lookup for user $id failed: $($_.Exception.Message)"
                    $failed++
                }
            }
        }
    }
    return @{ Owners = $map; FailedCount = $failed }
}

# --- Parameters ---------------------------------------------------------------------------

# Variables for authentication
$tenantId = $ctx.UserParameters["tenantId"]  # Azure AD Tenant ID
$clientId = $ctx.UserParameters["clientId"]  # Azure AD App Registration Client ID
$clientSecret = $ctx.UserParameters["clientSecret"]  # Azure AD App Registration Client Secret
$scanOnlyMobileDevices = $ctx.UserParameters["scanOnlyMobileDevices"] # Boolean to determine if only mobile devices should be scanned (optional)

if (-not (HasValue $tenantId) -or -not (HasValue $clientId) -or -not (HasValue $clientSecret)) {
    Notify -name "Error" -itemName "Parameters" -message "The parameters tenantId, clientId and clientSecret are required." -category "Error" -state "Faulty" -itemResult "Error"
    exit 1
}

# --- Access token -----------------------------------------------------------------------

$token = Get-GraphAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
if (-not $token.AccessToken) {
    Notify -name "Error" -itemName "Access Token" -message "Could not get an access token for tenant $($tenantId) ($($token.Error)). Check tenantId, clientId and clientSecret." -category "Error" -state "Faulty" -itemResult "Error"
    exit 1
}

$graphHeaders = @{
    "Authorization" = "Bearer $($token.AccessToken)"
    "Accept"        = "application/json"
}

# --- Retrieve Intune device information (managed devices) ------------------------------

$deviceFields = 'id,deviceName,managedDeviceName,model,manufacturer,operatingSystem,osVersion,userId,imei,wiFiMacAddress,phoneNumber,serialNumber,totalStorageSpaceInBytes,freeStorageSpaceInBytes,enrolledDateTime,subscriberCarrier'
$devicesUri = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=' + $deviceFields

try {
    $devices = @(Get-GraphCollection -Uri $devicesUri -Headers $graphHeaders -Permission 'DeviceManagementManagedDevices.Read.All')
}
catch {
    Notify -name "Error" -itemName "Intune Devices" -message "$($_.Exception.Message)" -category "Error" -state "Faulty" -itemResult "Error"
    exit 1
}

# Mobile devices are named by managedDeviceName. If the list returned it empty, read the single device
# (the single-device request returns the full property set).
foreach ($device in $devices) {
    if ($device.operatingSystem -in @("iOS", "Android") -and -not (HasValue $device.managedDeviceName) -and (HasValue $device.id)) {
        $uri = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/' + [uri]::EscapeDataString([string]$device.id)
        try {
            $single = Invoke-GraphGet -Uri $uri -Headers $graphHeaders -Permission 'DeviceManagementManagedDevices.Read.All'
            Write-CommonDebug -Context $ctx -Message "managedDeviceName missing in list for $($device.id), single request returned '$($single.managedDeviceName)'"
            if (HasValue $single.managedDeviceName) {
                $device | Add-Member -NotePropertyName 'managedDeviceName' -NotePropertyValue $single.managedDeviceName -Force
            }
        }
        catch {
            Write-CommonDebug -Context $ctx -Message "Single request for $($device.id) failed: $($_.Exception.Message)"
        }
    }
}

$numberOfMobileDevices = $devices | Where-Object { $_.operatingSystem -in @("iOS", "Android") } | Measure-Object | Select-Object -ExpandProperty Count

$message = "Found $($devices.Count) devices in Intune, of which $numberOfMobileDevices are mobile devices."

if ($scanOnlyMobileDevices -eq "true") {
    $message = "Found $numberOfMobileDevices mobile devices in Intune."
}

# Output the number of devices found to the Job Monitor
Notify -name "Information" -itemName "Evaluation" -itemResult "None" -message $message -category "Info" -state "Detecting"

# --- Owner lookup (one request per 15 users instead of one per device) ------------------

$ownerIds = @($devices |
    Where-Object { -not ($scanOnlyMobileDevices -eq "true" -and $_.operatingSystem -notin @("iOS", "Android")) } |
    ForEach-Object { [string]$_.userId } |
    Where-Object { $_ -ne "" } |
    Sort-Object -Unique)

$owners = @{}
if ($ownerIds.Count -gt 0) {
    try {
        $ownerLookup = Get-OwnerMap -UserIds $ownerIds -Headers $graphHeaders
        $owners = $ownerLookup.Owners
        if ($ownerLookup.FailedCount -gt 0) {
            Notify -name "Owner Lookup" -itemName "Owner" -message "The owner of $($ownerLookup.FailedCount) of $($ownerIds.Count) users could not be read; the affected devices are inventoried without owner. Details in the debug log." -category "Info" -state "Finished"
        }
    }
    catch {
        if ($_.Exception.Data['StatusCode'] -eq 403) {
            # Not an error of the scan: the devices are complete, only the owner is missing (as in AzureAd-Devices-Compliant.ps1)
            Notify -name "Owner Lookup" -itemName "Owner" -message "Devices are inventoried without owner, because the app registration may not read users. Grant the application permission 'User.Read.All' (admin consent required)." -category "Info" -state "Finished"
        }
        else {
            Notify -name "Owner Lookup" -itemName "Owner" -message "Device owners could not be determined, devices are inventoried without owner. $($_.Exception.Message)" -category "Error" -state "Faulty" -itemResult "Error"
        }
        $owners = @{}
    }
}

# --- Process the data ---------------------------------------------------------------------

foreach($device in $devices) {

    # Set ChassisType to "Mobile" for iOS and Android, leave empty for other devices as unknown
    # Use normal DeviceName for PCs, ManagedDeviceName for mobile devices: For smartphones, DeviceName is often "iPhone", which is not unique
    $chassisType = ""
    $name = $device.deviceName
    if ($device.operatingSystem -in @("iOS", "Android")) {
        $chassisType = "Mobile"
        # No fallback to deviceName: it is often just "iPhone", so several devices would end up in one asset
        $name = $device.managedDeviceName
    }

    # Skip non-mobile devices if "scanOnlyMobileDevices" is true
    if ($scanOnlyMobileDevices -eq "true" -and $chassisType -ne "Mobile") {
        continue
    }

    # A device without a usable name cannot be stored in LOGINventory.
    # The Intune id is part of the name, so every skipped device gets its own Job Monitor row.
    if (-not (HasValue $name)) {
        $missingField = if ($chassisType -eq "Mobile") { "managedDeviceName" } else { "deviceName" }
        Notify -name "Device without name ($($device.id))" -itemName "Inventory" -message "Skipped an Intune device without $missingField (Intune id $($device.id), device name '$($device.deviceName)', serial number $($device.serialNumber))." -category "Info" -state "Finished" -ItemResult "None"
        continue
    }

    # Create a new device
    NewEntity -name "Device"

    # Device name
    AddPropertyValue -name "Name"  -value $name

    # Reactivate archived assets
    AddPropertyValue -name "Archived" -value ""

    # Device serial number
    AddPropertyValue -name "SerialNumber" -value $device.serialNumber

    # Device type
    AddPropertyValue -name "DeviceInfo.ChassisType" -value $chassisType

    # Device model and manufacturer
    AddPropertyValue -name "HardwareProduct.Manufacturer{Editable:true}" -value $device.manufacturer
    AddPropertyValue -name "HardwareProduct.Name" -value $device.model

    # Device operating system, version, and installation date
    AddPropertyValue -name "OperatingSystem.Name" -value $device.operatingSystem
    AddPropertyValue -name "OperatingSystem.Version" -value $device.osVersion
    AddPropertyValue -name "OperatingSystem.InstallDate" -value (ConvertTo-GraphModuleDateString $device.enrolledDateTime)

    # Device storage space (only for mobile devices)
    if($chassisType -eq "Mobile") {
        $totalSpace = ([double]$device.totalStorageSpaceInBytes) / 1048576
        $freeSpace = ([double]$device.freeStorageSpaceInBytes) / 1048576
        $spacePercentage = [math]::Round(($freeSpace / $totalSpace) *100)
        AddPropertyValue -name "Partition.Name" -value "Main Storage"
        AddPropertyValue -name "Partition.TotalSpace" -value $totalSpace
        AddPropertyValue -name "Partition.FreeSpace" -value $freeSpace
        AddPropertyValue -name "Partition.FreeSpacePc" -value $spacePercentage
    }

    # Determine and set the owner of the device (users that no longer exist are not in $owners)
    if ($device.userId -ne $null -and $device.userId -ne "") {
        $ownerData = $owners[[string]$device.userId]
        if (($null -ne $ownerData.onPremisesDomainName) -and ($null -ne $ownerData.onPremisesSamAccountName)) {
            AddPropertyValue -name "Owner.Name" -value "$($ownerData.onPremisesDomainName)\$($ownerData.onPremisesSamAccountName)"
        }
    }

    # Device MAC address
    $fromattedMac = ($device.wiFiMacAddress -replace "..", '$&:').TrimEnd(':').ToUpper()
    AddPropertyValue -name "LastInventory.Mac" -value $fromattedMac

    # Set inventory method to "Stub" for non-mobile devices: When a Windows machine is scanned directly, the values read from Intune will not overwrite the values from the direct scan.
    if($chassisType -ne "Mobile") {
        AddPropertyValue -name "LastInventory.Method" -value "Stub"
    }

    # Device IMEI
    AddPropertyValue -name "MobileDeviceInfo.DeviceImei" -value $device.imei

    # Device phone number
    AddPropertyValue -name "MobileDeviceInfo.PhoneNumber" -value $device.phoneNumber

    # Device mobile carrier
    AddPropertyValue -name "MobileDeviceInfo.MobileOperator" -value $device.subscriberCarrier

    Notify -name $name -itemName "Inventory" -message $name -category "Info" -state "Finished" -ItemResult "Ok"
}

# Define file name and file path
$fileName = "$($ctx.TimeStamp)@Intune.inv"
$filePath = "$($ctx.DataDir)\$fileName"

# Generate inventory file and save it in the data directory
WriteInv -filePath "$filePath" -version $ctx.Version

# Notify LOGINventory Job Monitor
Notify -name "Writing Data" -itemName "Inventory" -itemResult "Ok" -message "Intune" -category "Info" -state "Finished"

# Same name as the "Detecting" event above, so the Job Monitor completes that row
Notify -name "Information" -itemName "Evaluation" -itemResult "Ok" -message $message -category "Info" -state "Finished"
