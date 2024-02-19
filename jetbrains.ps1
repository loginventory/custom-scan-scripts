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

Write-Host "Tenant: $($scope.Parameters["Tenant"])"

Notify -name "Datadir" -itemName "Data Directory" -message $($scope.DataDir) -category "Info" -state "None" -info "hallo"

$apiKey = Decode -value $scope.Credentials[0].Password
$customerCode = $scope.Credentials[0].Username
$uri = "https://account.jetbrains.com/api/v1/customer/licenses"

$headers = @{
    "X-Customer-Code" = $customerCode
    "X-Api-Key"       = $apiKey
    "Accept"          = "application/json"
}

try {
    
    SetEntityName -name "User"

    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

    foreach ($item in $response) {                
        $productObj = ToValidJson -dataString $item.product | ConvertFrom-Json
        $assigneeObj = ToValidJson -dataString $item.assignee | ConvertFrom-Json
        $subscriptionObj = ToValidJson -dataString $item.Subscription | ConvertFrom-Json
        
        NewEntity
        AddPropertyValue -name "Name" -value $assigneeObj.email

        AddPropertyValue -name "CloudSubscription.Publisher" -value "JetBrains"
        AddPropertyValue -name "CloudSubscription.Source" -value "JetBrains API"
        AddPropertyValue -name "CloudSubscription.TenantId" -value $customerCode
        AddPropertyValue -name "CloudSubscription.TenantName" -value $scope.Parameters['Tenant']
        AddPropertyValue -name "CloudSubscription.Name" -value $productObj.name
        AddPropertyValue -name "CloudSubscription.SkuId" -value "$($productObj.code) $($subscriptionObj.SubscriptionPackRef)"
        AddPropertyValue -name "CloudSubscription.SkuPartNumber" -value $subscriptionObj.SubscriptionPackRef
        AddPropertyValue -name "CloudSubscription.ObjectId" -value $item.licenseId        
    }

    Notify -name "Writing Data" -itemName "JetApi" -message $filePath -category "Info" -state "None"
    WriteInv -filePath $filePath -version $scope.Version
    Notify -name "Writing Data Done" -itemName "JetApi" -message $filePath -category "Info" -state "Finished"
}
catch {
    Notify -name "JetApi" -itemName "Error" -message "$_ - $($_.InvocationInfo.ScriptLineNumber)" -category "Error"  -state "Faulty"
}