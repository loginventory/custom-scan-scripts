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

$scope = Init -encodedParams $parameter
#end of default header ----------------------------------------------------------------------
$filePath = "$($scope.DataDir)\adobe-$($scope.TimeStamp).inv"

$organizationId = $scope.Parameters["organizationId"]
$clientId = $scope.Parameters["clientId"]
$clientSecret = $scope.Parameters["clientSecret"]
$tenantName = $scope.Parameters["tenantName"]

$env:DEBUG = "false"
$DebugMode = [System.Convert]::ToBoolean($env:DEBUG)

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

    try {
        $body = ConvertTo-UrlEncoded -Hashtable $FormData
        $response = Invoke-RestMethod -Uri $Uri -Method Post -Body $body -Headers $Headers -ErrorAction Stop
        Notify -name "Response Received" -itemName "Response Received" -itemResult "None" -message "Access Token Granted" -category "Info" -state "Finished"
        return $response
    }
    catch {
        Write-Error "Failed to get access token: $($_.Exception.Message)"
        Write-Host "Status Code: $($_.Exception.Response.StatusCode)"
        Write-Host "Response: $($_.Exception.Response.Content.ReadAsStringAsync().Result)"
        return $null
    }
}

try {

    if ($DebugMode) {
        Write-Host "Reading token from file"
        $token = Get-Content -Raw -Path ".\data\token.json" | ConvertFrom-Json
        Write-Host "Access Token: $($token.access_token)"
        Write-Host "Expires In: $($token.expires_in)"
        Write-Host "Token Type: $($token.token_type)"
    }
    else {
        $token = Get-Access-Token -Uri $loginUri -FormData $formData -Headers $headers
    }

    if ($token) {
        #some debug output possible here
    }
    else {
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
    try {
        $response= Invoke-RestMethod -Uri $usersUri -Method Get -Headers $groupHeaders
        $usersResponse += $response.users       
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 429) {
            $retryAfter = $_.Exception.Response.Headers.GetValues("Retry-After")[0]
            $retryAfterMinutes = [math]::Ceiling($retryAfter / 60)
            Notify -name "Request Failed" -itemName "Request Failed" -itemResult "Error" -message "Too many requests. Retry after $retryAfter seconds ($retryAfterMinutes minutes)." -category "Error" -state "Faulty"
            
            exit
        }
        else {
            throw $_
        }
    }
    Notify -name "Got Users" -itemName "Got Users" -itemResult "None" -message "Got users from page $userindex" -category "Info" -state "None"
    $userindex++
    $usersUri = "$userManagementUri/usermanagement/users/$organizationId/$userindex"
    if ($response.lastPage -eq $true) {
        $lastPageUsers = $true
    }
}

while ($lastPageGroups -eq $false) {
    try {
        $response2= Invoke-RestMethod -Uri $orgGroupsUri -Method Get -Headers $groupHeaders
        $groupsResponse += $response2.groups
        }
    catch {
        if ($_.Exception.Response.StatusCode -eq 429) {
            $retryAfter = $_.Exception.Response.Headers.GetValues("Retry-After")[0]
            $retryAfterMinutes = [math]::Ceiling($retryAfter / 60)
            Write-Host "Too many requests. Retry after $retryAfter seconds ($retryAfterMinutes minutes)."
            exit
        }
        else {
            throw $_
        }
    }
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
WriteInv -filePath $filePath -version $scope.Version
Notify -name "Writing Data Done" -itemName "AdobeApi" -message "-" -category "Info" -state "Finished" -itemResult "Ok"