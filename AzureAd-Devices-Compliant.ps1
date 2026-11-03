<#
.SYNOPSIS
Ein Skript zur Erfassung von Azure AD Geräteinformationen über Microsoft Graph.

.DESCRIPTION
Dieses Skript ruft über die Microsoft Graph REST API Informationen über Geräte in Azure Active Directory (Microsoft Entra ID) ab. Es liest unter anderem den Compliant Status der Geräte aus und erzeugt für diesen eine Eigene Eigenschaft (Compliant), welche dann in LOGINventory zur Verfügung steht.
Die gesammelten Informationen werden zur Weiterverarbeitung für LOGINsert in eine .inv Datei geschrieben.

Das Skript benötigt keine zusätzlichen PowerShell-Module (das Modul Microsoft.Graph wird nicht mehr verwendet).
Die Anfragen laufen über include\WebRequest.ps1 und berücksichtigen damit die Proxy-Einstellungen von LOGINventory.

.AUTHOR
Schmidt's LOGIN GmbH - [www.loginventory.de](https://www.loginventory.de)

.VERSION
2.0.0

.LICENSE
Dieses Skript ist unter der MIT-Lizenz lizenziert. Vollständige Lizenzinformationen finden Sie unter [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

.NOTES
Im Ordner "include" neben dem Skript müssen die Dateien common.ps1 und WebRequest.ps1 liegen.

Die verwendete App Registration benötigt folgende Microsoft Graph Berechtigungen vom Typ "Application permissions",
jeweils mit "Admin Consent granted" (in der App Registration unter "API Permissions"):
- Device.Read.All    Lesen der Geräte und ihrer registrierten Benutzer (erforderlich)
- User.Read.All      Lesen des Benutzerprinzipalnamens (UPN) des registrierten Benutzers

Fehlt Device.Read.All, bricht das Skript mit einem entsprechenden Fehler im Job Monitor ab.
Fehlt User.Read.All, liefert Microsoft Graph die registrierten Benutzer ohne UPN. Die Geräte werden dann ohne
Benutzerzuordnung übernommen und im Job Monitor erscheint ein Hinweis.

Diese Zugangsdaten können Sie dann im RemoteScanner in der Skriptbasierten Inventarisierung unter Parameter tenantId, clientId und clientSecret hinterlegen, oder hier direkt verwenden.

.PARAMETER
Diese Zugangsdaten können Sie im RemoteScanner in der Skriptbasierten Inventarisierung unter Parameter, oder hier direkt verwenden.
- tenantId
- clientId
- clientSecret
- nameFilter (optional, z.B. mit name* können Sie die Geräte filtern, die in die .inv Datei aufgenommen werden sollen, wobei * ein Wildcard ist.)
- enabledAccountsOnly (wenn true nur Geräte mit aktivierten Accounts aufnehmen);
- validCompliantStatesOnly (wenn true nur Geräte mit gültigen Compliance-Status aufnehmen);
#>

#default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)

. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "include\WebRequest.ps1")

$ctx = New-CommonContext -Parameters $parameter -StartLabel 'AzureAD'
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

# --- Parameters ---------------------------------------------------------------------------

$filePath = "$($ctx.DataDir)\azure-$($ctx.TimeStamp).inv"

$namefilter = $ctx.UserParameters["namefilter"];
$enabledAccountsOnly = $ctx.UserParameters["enabledAccountsOnly"] -eq "true";
$validCompliantStatesOnly = $ctx.UserParameters["validCompliantStatesOnly"] -eq "true";

$TenantId = $ctx.UserParameters["tenantId"]
$ClientId = $ctx.UserParameters["clientId"]
$ClientSecret = $ctx.UserParameters["clientSecret"]

if (-not (HasValue $TenantId) -or -not (HasValue $ClientId) -or -not (HasValue $ClientSecret)) {
    Notify -name "Error" -itemName "Parameters" -message "The parameters tenantId, clientId and clientSecret are required." -category "Error" -state "Faulty" -itemResult "Error"
    exit 1
}

# --- Access token -----------------------------------------------------------------------

Notify -name "Connect" -itemName "MSGRAPH" -message "Connecting-Tenant: $($TenantId)" -category "Info" -state "Executing"
$token = Get-GraphAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
if (-not $token.AccessToken) {
    Notify -name "Connect" -itemName "MSGRAPH" -message "Could not get an access token for tenant $($TenantId) ($($token.Error)). Check tenantId, clientId and clientSecret." -category "Error" -state "Faulty" -itemResult "Error"
    exit 1
}
Notify -name "Connect" -itemName "MSGRAPH" -message "Ok" -category "Info" -state "Finished"

$graphHeaders = @{
    "Authorization" = "Bearer $($token.AccessToken)"
    "Accept"        = "application/json"
}

# --- Devices (with their registered users in the same request) --------------------------

Notify -name "Getting Devices" -itemName "MSGRAPH" -message "..." -category "Info" -state "Executing"

$deviceFields = 'id,displayName,accountEnabled,isCompliant,operatingSystem,operatingSystemVersion'
$devicesBaseUri = 'https://graph.microsoft.com/v1.0/devices?$select=' + $deviceFields

# $expand returns at most 20 registered users per device; only the first one is used anyway.
# Directory objects do not support $select inside $expand, so the users come with their default properties.
$expandRegisteredUsers = $true
try {
    try {
        $devices = @(Get-GraphCollection -Uri ($devicesBaseUri + '&$expand=registeredUsers') -Headers $graphHeaders -Permission 'Device.Read.All')
    }
    catch {
        if ($_.Exception.Data['StatusCode'] -ne 400) { throw }
        # Expand rejected by the tenant: read devices only and ask for the registered users per device.
        Write-CommonDebug -Context $ctx -Message "Expanding registeredUsers rejected ($($_.Exception.Message)), falling back to one request per device"
        $expandRegisteredUsers = $false
        $devices = @(Get-GraphCollection -Uri $devicesBaseUri -Headers $graphHeaders -Permission 'Device.Read.All')
    }
}
catch {
    Notify -name "Getting Devices" -itemName "MSGRAPH" -message "$($_.Exception.Message)" -category "Error" -state "Faulty" -itemResult "Error"
    exit 1
}

Notify -name "Getting Devices" -itemName "MSGRAPH" -message "Found $($devices.Count) Devices" -category "Info" -state "Finished"

function Get-FirstRegisteredUser {
    <#
    .SYNOPSIS
        Returns the first registered user of a device (or $null). Only one owner can be stored.
    #>
    param($Device)

    if ($expandRegisteredUsers) {
        return @($Device.registeredUsers)[0]
    }
    $uri = 'https://graph.microsoft.com/v1.0/devices/' + [uri]::EscapeDataString([string]$Device.id) + '/registeredUsers'
    try {
        $page = Invoke-GraphGet -Uri $uri -Headers $graphHeaders -Permission 'Device.Read.All'
        return @($page.value)[0]
    }
    catch {
        # Like before: a failed owner lookup does not stop the inventory of the device.
        Write-CommonDebug -Context $ctx -Message "Registered users of $($Device.displayName) could not be read: $($_.Exception.Message)"
        return $null
    }
}

$usersWithoutUpn = 0

try {
    foreach ($device in $devices) {
        if ($namefilter -and $device.DisplayName -notlike $namefilter) {
            continue
        }

        if ($true -eq $enabledAccountsOnly -and $false -eq $device.AccountEnabled) {
            Notify -name $device.DisplayName -itemName "MSGRAPH" -message "Dropping Device, Account Not Enabled: $($device.DisplayName) Compliant: $($device.IsCompliant)" -category "Info"  -state "Finished"
            continue
        }

        if ($true -eq $validCompliantStatesOnly -and $false -ne $device.IsCompliant -and $true -ne $device.IsCompliant) {
            Notify -name $device.DisplayName -itemName "MSGRAPH" -message "Dropping Device, no valid compliance state: $($device.DisplayName) Compliant: $($device.IsCompliant)" -category "Info"  -state "Finished"
            continue
        }

        Notify -name $device.DisplayName -itemName "MSGRAPH" -message "Device: $($device.DisplayName) Compliant: $($device.IsCompliant)" -category "Info"  -state "Finished"

        $compliantValue = if ($null -eq $device.IsCompliant) { "n/v" } else { $device.IsCompliant }

        NewEntity -name "Device"
        AddPropertyValue -name "Name" -value $device.DisplayName
        # Reactive archived assets
        AddPropertyValue -name "Archived" -value ""
        AddPropertyValue -name "Custom.Compliant" -value $compliantValue
        AddPropertyValue -name "LastInventory.Timestamp" -value $ctx.TimeStamp2
        AddPropertyValue -name "OperatingSystem.Name" -value $($device.OperatingSystem)
        AddPropertyValue -name "OperatingSystem.Version" -value $($device.OperatingSystemVersion)

        # We can only handle one owner: the first registered user
        $owner = Get-FirstRegisteredUser -Device $device
        if ($null -ne $owner) {
            $UPN = [string]$owner.userPrincipalName
            if ($UPN) {
                $UserName, $domain = $UPN -split "@"
                AddPropertyValue -name "DeviceUsage.Domain" -value $($domain)
                AddPropertyValue -name "DeviceUsage.UserName" -value $($UserName)
                AddPropertyValue -name "DeviceUsage.Upn" -value $($UPN)
            }
            elseif ([string]$owner.'@odata.type' -eq '#microsoft.graph.user') {
                # Graph hides user properties if the app may not read users (User.Read.All missing)
                $usersWithoutUpn++
            }
        }
    }

    if ($usersWithoutUpn -gt 0) {
        Notify -name "Registered Users" -itemName "MSGRAPH" -message "For $usersWithoutUpn devices the registered user has no readable user principal name, so no user was assigned. Grant the application permission 'User.Read.All' (admin consent required)." -category "Info" -state "Finished"
    }

    Notify -name "Writing Data" -itemName "MSGRAPH" -message $filePath -category "Info" -state "Executing"
    WriteInv -filePath $filePath -version $ctx.Version
    Notify -name "Writing Data" -itemName "MSGRAPH" -message $filePath -category "Info" -state "Finished"
}
catch {
    Notify -name "ERROR" -itemName "Error" -message "$_ - $($_.InvocationInfo.ScriptLineNumber)" -category "Error"  -state "Faulty" -itemResult "Error"
}
