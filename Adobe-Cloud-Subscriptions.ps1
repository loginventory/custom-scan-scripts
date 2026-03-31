<#
.SYNOPSIS
A script to collect license information from Adobe products using the Adobe User Management API.

.DESCRIPTION
This script uses the Adobe User Management API to retrieve information about users and their associated licenses.
The collected information is written to an .inv file for further processing by the Data Service.

.AUTHOR
Schmidt's LOGIN GmbH

.VERSION
1.0.0

.LICENSE
This script is licensed under the MIT License. Full license information can be found at [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

.NOTES
In order to use this script, you need to create an API key according to the following Adobe Instructions: https://developer.adobe.com/developer-console/docs/guides/authentication/ServerToServerAuthentication/implementation/

Adobe offers several APIs, you need to select the "User Management API" in the Adobe Developer Console. If you cannot find it directly, remove any filters in the API selection and search for "User Management API (UMAPI)": https://adobe-apiplatform.github.io/umapi-documentation/en/

The script requires the following parameters to execute correctly:

.PARAMETER
You can use these credentials in the RemoteScanner under script-based inventory in the Parameters section, or directly here:
- organizationId (e.g. "1234567890@AdobeOrg")
- clientId (e.g. "1234567890abcdef1234567890abcdef")
- clientSecret (e.g. "1234567890abcdef1234567890abcdef")
- tenantName (e.g. "YourTenantName")

When specifying the values in the Remote Scanner, quotation marks can be omitted.
#>

#default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)
. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "include\WebRequest.ps1")

$ctx = New-CommonContext -Parameters $parameter -StartLabel 'Adobe'
#end of default header ----------------------------------------------------------------------
$filePath = "$($ctx.DataDir)\adobe-$($ctx.TimeStamp).inv"

$organizationId = $ctx.UserParameters["organizationId"]
$clientId = $ctx.UserParameters["clientId"]
$clientSecret = $ctx.UserParameters["clientSecret"]
$tenantName = $ctx.UserParameters["tenantName"]

$loginUri = "https://ims-na1.adobelogin.com/ims/token/v3"
$userManagementUri = "https://usermanagement.adobe.io/v2"
$orgGroupsUri = "$userManagementUri/usermanagement/groups/$organizationId"
$usersUri = "$userManagementUri/organizations/$organizationId/users"


$formData = @{
    "grant_type"    = "client_credentials"
    "client_id"     = $clientId
    "client_secret" = $clientSecret
    "scope"         = "openid,AdobeID,user_management_sdk"
}

$headers = @{
    "Content-Type" = "application/x-www-form-urlencoded"
}

function ConvertTo-UrlEncoded {
    param ($Hashtable)
    ($Hashtable.GetEnumerator() | ForEach-Object { "$($_.Key)=" + [uri]::EscapeDataString($_.Value) }) -join "&"
}

function Get-Access-Token {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [hashtable]$FormData,
        [Parameter(Mandatory = $false)]
        [hashtable]$Headers = @{ "Content-Type" = "application/x-www-form-urlencoded" }
    )
    Notify -name "Getting Access Token" -itemName "Getting Access Token" -itemResult "None" -message "Getting Access Token from $Uri" -category "Info" -state "None"

    $body = ConvertTo-UrlEncoded -Hashtable $FormData
    $resp = Invoke-LoginWebRequest -Uri $Uri -Method POST -Body $body -Headers $Headers -ProxyConfig $ctx.ProxyConfig -DebugFile $ctx.DebugFile

    if (-not $resp.IsSuccess) {
        Write-Error "Failed to get access token: HTTP $($resp.StatusCode) $($resp.StatusDescription)"
        return $null
    }

    Notify -name "Response Received" -itemName "Response Received" -itemResult "None" -message "Access Token Granted" -category "Info" -state "Finished"
    return ($resp.Body | ConvertFrom-Json)
}

try {
    $token = Get-Access-Token -Uri $loginUri -FormData $formData -Headers $headers

    if (-not $token) {
        Write-Host "Failed to get token."
        exit 1
    }
}
catch {
    Write-Host "Outer catch: $($_.Exception.Message)"
    exit 1
}

$groupHeaders = @{
    "Authorization" = "Bearer $($token.access_token)"
    "x-api-key"     = $formData["client_id"]
}


$userindex = 0 
$groupindex = 0
$lastPageUsers = $false
$lastPageGroups = $false

$usersResponse = @()
$groupsResponse = @()

$orgGroupsUri = "$userManagementUri/usermanagement/groups/$organizationId/$groupindex"
$usersUri = "$userManagementUri/usermanagement/users/$organizationId/$userindex"

Notify -name "Requesting Users and Groups" -itemName "Requesting Users and Groups" -itemResult "None" -message "Requesting Users and Groups from Adobe Management API" -category "Info" -state "None"

while ($lastPageUsers -eq $false) {
    $resp = Invoke-LoginWebRequest -Uri $usersUri -Method GET -Headers $groupHeaders -ProxyConfig $ctx.ProxyConfig -DebugFile $ctx.DebugFile

    if (-not $resp.IsSuccess) {
        if ($resp.StatusCode -eq 429) {
            $retryAfter = if ($resp.Headers -and $resp.Headers["Retry-After"]) { $resp.Headers["Retry-After"] } else { "unknown" }
            Notify -name "Request Failed" -itemName "Request Failed" -itemResult "Error" -message "Too many requests. Retry after $retryAfter seconds." -category "Error" -state "Faulty"
            exit
        }
        Write-Host "Fehler beim Abrufen der Users: HTTP $($resp.StatusCode) $($resp.StatusDescription)"
        exit 1
    }

    $response = $resp.Body | ConvertFrom-Json
    $usersResponse += $response.users
    Notify -name "Got Users" -itemName "Got Users" -itemResult "None" -message "Got users from page $userindex" -category "Info" -state "None"
    $userindex++
    $usersUri = "$userManagementUri/usermanagement/users/$organizationId/$userindex"
    if ($response.lastPage -eq $true) {
        $lastPageUsers = $true
    }
}

while ($lastPageGroups -eq $false) {
    $resp2 = Invoke-LoginWebRequest -Uri $orgGroupsUri -Method GET -Headers $groupHeaders -ProxyConfig $ctx.ProxyConfig -DebugFile $ctx.DebugFile

    if (-not $resp2.IsSuccess) {
        if ($resp2.StatusCode -eq 429) {
            $retryAfter = if ($resp2.Headers -and $resp2.Headers["Retry-After"]) { $resp2.Headers["Retry-After"] } else { "unknown" }
            Write-Host "Too many requests. Retry after $retryAfter seconds."
            exit
        }
        Write-Host "Fehler beim Abrufen der Groups: HTTP $($resp2.StatusCode) $($resp2.StatusDescription)"
        exit 1
    }

    $response2 = $resp2.Body | ConvertFrom-Json
    $groupsResponse += $response2.groups
    Notify -name "Got Groups" -itemName "Got Groups" -itemResult "None" -message "Got groups from page $groupindex" -category "Info" -state "None"
    $groupindex++
    $orgGroupsUri = "$userManagementUri/usermanagement/groups/$organizationId/$groupindex"
    if ($response2.lastPage -eq $true) {
        $lastPageGroups = $true
    }
}

$licenseGroups = $groupsResponse | Where-Object { $_.licenseQuota } | ForEach-Object {
    [PSCustomObject]@{
        GroupName    = $_.groupName
        ProductName  = $_.productName
        LicenseQuota = $_.licenseQuota
        MemberCount  = $_.memberCount
        GroupId      = $_.groupId
    }
}
$productGroupNames = $licenseGroups.GroupName

$users = $usersResponse | Where-Object {
    $userGroups = $_.groups
    $productGroupNames | Where-Object { $_ -in $userGroups }
} | ForEach-Object {
    $filteredGroups = $_.groups | Where-Object { $_ -in $productGroupNames }
    [PSCustomObject]@{
        FirstName = $_.firstname
        LastName  = $_.lastname
        Email     = $_.email
        Groups    = $filteredGroups
    }
}

$licenseList = @()

Notify -name "Information" -itemName "Information" -itemResult "None" -message "Creating user objects" -category "Info" -state "None"

foreach ($user in $users) {
    NewEntity -name "User"
    AddPropertyValue -name "Name" -value $user.Email
    foreach ($group in $user.Groups) {
        $matchingGroup = $licenseGroups | Where-Object { $_.GroupName -eq $group }

        # Extract the first part (until the first bracket) and trim spaces
        if ($matchingGroup.ProductName -match "^(.*?)\s*\(") {
            $productName = $matches[1].Trim()
        }
        else {
            $productName = $matchingGroup.ProductName
        }

        # Extract the ID at the end (after the dash) and trim spaces
        if ($matchingGroup.ProductName -match "-\s*([A-Fa-f0-9]+)\)") {
            $id = $matches[1].Trim()
        }
        else {
            $id= "not available"
        }

        AddPropertyValue -name "CloudSubscription.Publisher" -value "Adobe"
        AddPropertyValue -name "CloudSubscription.Source" -value "Adobe User Management API"
        AddPropertyValue -name "CloudSubscription.TenantId" -value $organizationId
        AddPropertyValue -name "CloudSubscription.TenantName" -value $tenantName
        AddPropertyValue -name "CloudSubscription.Name" -value $productName
        AddPropertyValue -name "CloudSubscription.SkuId" -value $id
        AddPropertyValue -name "CloudSubscription.SkuPartNumber" -value $matchingGroup.ProductName
        AddPropertyValue -name "CloudSubscription.ObjectId" -value $matchingGroup.GroupId
        AddPropertyValue -name "CloudSubscription.Consumed" -value $matchingGroup.LicenseQuota
        AddPropertyValue -name "CloudSubscription.Enabled" -value $matchingGroup.MemberCount
        
        # only add the license if it is not already in the list
        if ($licenseList -notcontains $matchingGroup.ProductName) {
            $licenseList += $matchingGroup.ProductName
        
            NewEntity -name "ProductSubscriptionLicense"
            AddPropertyValue -name "TenantId" -value $organizationId
            AddPropertyValue -name "TenantName" -value $tenantName
            $gulid = $id + "_" + $organizationId
            AddPropertyValue -name "Gulid" -value $gulid
            AddPropertyValue -name "Name{Editable:true}" -value $productName
            AddPropertyValue -name "Manufacturer{Editable:true}" -value "Adobe"
            AddPropertyValue -name "Amount{Editable:true}" -value $matchingGroup.LicenseQuota
            AddPropertyValue -name "Multiplicator{Editable:true}" -value "1"
            AddPropertyValue -name "EffectiveAmount{Editable:true}" -value $matchingGroup.LicenseQuota
            AddPropertyValue -name "Method{Editable:true}" -value "2" # equals "Rent"
            AddPropertyValue -name "LicenseType{Editable:true}" -value "0"
            AddPropertyValue -name "Kind{Editable:true}" -value "0"
        }
    }
}

Notify -name "Writing Data" -itemName "AdobeApi" -message $filePath -category "Info" -state "Running"
WriteInv -filePath $filePath -version $ctx.Version
Notify -name "Writing Data Done" -itemName "AdobeApi" -message "-" -category "Info" -state "Finished" -itemResult "Ok"