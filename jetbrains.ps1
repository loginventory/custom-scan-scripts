<#
.SYNOPSIS
Ein Skript zur Erhebung von JetBrains Produktlizenzinformationen über die JetBrains Account API.

.DESCRIPTION
Dieses Skript ruft Informationen zu JetBrains Produktlizenzen ab, indem es die JetBrains Account API anfragt. Es verwendet dabei API-Schlüssel und Kundeninformationen, um die Lizenzen abzurufen und sie in einer .inv Datei für LOGINventory zu speichern.

.AUTHOR
Schmidt's LOGIN GmbH - [www.loginventory.de](https://www.loginventory.de) 2024

.VERSION
1.0.0

.LICENSE
Dieses Skript ist unter der MIT-Lizenz lizenziert. Vollständige Lizenzinformationen finden Sie unter [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

.NOTES
Stellen Sie sicher, dass Sie über gültige JetBrains API-Zugangsdaten verfügen, um dieses Skript erfolgreich auszuführen.
Diese Zugangsdaten können Sie dann im RemoteScanner in der Skriptbasierten Inventarisierung unter Parameter apiKey und customerCode hinterlegen, oder hier direkt verwenden.
#>

#default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)

. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")

$scope = Init -encodedParams $parameter
#end of default header ----------------------------------------------------------------------


$filePath = "$($scope.DataDir)\jetbrains-$($scope.TimeStamp).inv"

function ToValidJson {
    param (
        [string]$dataString
    )
    $cleanDataString = $dataString -replace '^@{|}$', ''
    $pairs = $cleanDataString -split '; '
    $hashtable = @{}    
    foreach ($pair in $pairs) {
        if ($pair) {
            $keyValue = $pair -split '=', 2
            $key = $keyValue[0].Trim()
            $value = $keyValue[1].Trim()
            $hashtable[$key] = $value
        }
    }
    $json = $hashtable | ConvertTo-Json
    return $json
}

Notify -name "Datadir" -itemName "Data Directory" -message $($scope.DataDir) -category "Info" -state "None" -info "hallo"

$apiKey = $scope.Parameters["apiKey"]
$customerCode = $scope.Parameters["customerCode"]
$uri = "https://account.jetbrains.com/api/v1/customer/licenses"

$headers = @{
    "X-Customer-Code" = $customerCode
    "X-Api-Key"       = $apiKey
    "Accept"          = "application/json"
}

try {
        
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

    foreach ($item in $response) {                
        $product = ToValidJson -dataString $item.product | ConvertFrom-Json
        $assignee = ToValidJson -dataString $item.assignee | ConvertFrom-Json
        $subscription = ToValidJson -dataString $item.Subscription | ConvertFrom-Json
        #$lastSeen = ToValidJson -dataString $item.lastSeen | ConvertFrom-Json
        $team = ToValidJson -dataString $item.team | ConvertFrom-Json

        NewEntity -name "User"
        AddPropertyValue -name "Name" -value $assignee.email

        AddPropertyValue -name "CloudSubscription.Publisher" -value "JetBrains"
        AddPropertyValue -name "CloudSubscription.Source" -value $uri
        AddPropertyValue -name "CloudSubscription.TenantId" -value $team.id
        AddPropertyValue -name "CloudSubscription.TenantName" -value $team.name
        AddPropertyValue -name "CloudSubscription.Name" -value $product.name
        AddPropertyValue -name "CloudSubscription.SkuId" -value "$($subscription.SubscriptionPackRef)"
        AddPropertyValue -name "CloudSubscription.ObjectId" -value $item.licenseId        

        NewEntity -name "ProductSubscriptionLicense"
        AddPropertyValue -name "TenantId" -value $team.id
        AddPropertyValue -name "TenantName" -value $team.name
        AddPropertyValue -name "Number{Editable:true}" -value $item.licenseId
        AddPropertyValue -name "Name{Editable:true}" -value $product.name
        AddPropertyValue -name "Manufacturer{Editable:true}" -value "JetBrains"
        AddPropertyValue -name "Gulid" -value "$($subscription.SubscriptionPackRef)_$($team.id)"
        AddPropertyValue -name "Amount{Editable:true}" -value "1"
        AddPropertyValue -name "Multiplicator{Editable:true}" -value "1"
        AddPropertyValue -name "EffectiveAmount{Editable:true}" -value "1"
        AddPropertyValue -name "Method{Editable:true}" -value "0"
        AddPropertyValue -name "LicenseType{Editable:true}" -value "0"
        AddPropertyValue -name "Kind{Editable:true}" -value "0"
    }

    Notify -name "Writing Data" -itemName "JetApi" -message $filePath -category "Info" -state "Running"
    WriteInv -filePath $filePath -version $scope.Version
    Notify -name "Writing Data Done" -itemName "JetApi" -message $filePath -category "Info" -state "Finished" -itemResult "Ok"
}
catch {
    Notify -name "JetApi" -itemName "Error" -message "$_ - $($_.InvocationInfo.ScriptLineNumber)" -category "Error"  -state "Faulty"
}