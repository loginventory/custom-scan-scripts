<#
.SYNOPSIS
Ein Skript zur Erhebung von JetBrains Produktlizenzinformationen über die JetBrains Account API.

.DESCRIPTION
Dieses Skript ruft Informationen zu JetBrains Produktlizenzen ab, indem es die JetBrains Account API anfragt. Es verwendet dabei API-Schlüssel und Kundeninformationen, um die Lizenzen abzurufen und sie in einer .inv Datei für LOGINventory zu speichern.

.AUTHOR
Schmidt's LOGIN GmbH - [www.loginventory.de](https://www.loginventory.de) 2024

.VERSION
2.0.0

.LICENSE
Dieses Skript ist unter der MIT-Lizenz lizenziert. Vollständige Lizenzinformationen finden Sie unter [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

.NOTES
Stellen Sie sicher, dass Sie über gültige JetBrains API-Zugangsdaten verfügen, um dieses Skript erfolgreich auszuführen.

.PARAMETER
Diese Zugangsdaten können Sie im RemoteScanner in der Skriptbasierten Inventarisierung unter Parameter, oder hier direkt verwenden.
- apiKey
- customerCode
#>

#default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)

. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "include\WebRequest.ps1")

$ctx = New-CommonContext -Parameters $parameter -StartLabel 'JetBrains'
#end of default header ----------------------------------------------------------------------


$filePath = "$($ctx.DataDir)\jetbrains-$($ctx.TimeStamp).inv"

Notify -name "Datadir" -itemName "Data Directory" -message $($ctx.DataDir) -category "Info" -state "None"

$apiKey = $ctx.UserParameters["apiKey"]
$customerCode = $ctx.UserParameters["customerCode"]
$uri = "https://account.jetbrains.com/api/v1/customer/licenses"

$headers = @{
    "X-Customer-Code" = $customerCode
    "X-Api-Key"       = $apiKey
    "Accept"          = "application/json"
}

# Unique identifier per product/subscription pack/team.
# NOTE: subscriptionPackRef alone is NOT product-specific - one pack (e.g. an
# "All Products" contract) covers several products, so using it as SkuId/Gulid
# makes all products of the pack collide onto a single record in LOGINventory.
# Combine it with the product code. Outdated/expired subscriptions have no
# subscriptionPackRef at all; fall back to the product code alone.
function Get-SkuId {
    param ($item)
    $packRef = $item.subscription.subscriptionPackRef
    if ($packRef) {
        return "$($packRef)_$($item.product.code)"
    }
    return "$($item.product.code)"
}

try {

    $resp = Invoke-LoginWebRequest -Uri $uri -Method GET -Headers $headers -ProxyConfig $ctx.ProxyConfig -DebugFile $ctx.DebugFile

    if (-not $resp.IsSuccess) {
        Write-Host "Fehler beim Abrufen der JetBrains-Lizenzen: HTTP $($resp.StatusCode) $($resp.StatusDescription)"
        exit 1
    }

    $response = $resp.Body | ConvertFrom-Json

    # A license counts as assigned only if there is an assignee we can name a user
    # entity after - an empty user name is rejected by the import.
    function Test-Assigned {
        param ($item)
        return [bool]($item.assignee -and ($item.assignee.email -or $item.assignee.name))
    }

    # Aggregate the per-license API rows into one group per product/pack/team to get
    # the totals: Enabled = all licenses of the group, Consumed = assigned licenses.
    $licenseGroups = @{}
    foreach ($item in $response) {
        $skuId = Get-SkuId -item $item
        $groupKey = "$($skuId)_$($item.team.id)"
        if (-not $licenseGroups.ContainsKey($groupKey)) {
            $licenseGroups[$groupKey] = [PSCustomObject]@{
                SkuId       = $skuId
                ProductName = $item.product.name
                TeamId      = $item.team.id
                TeamName    = $item.team.name
                Total       = 0
                Assigned    = 0
            }
        }
        $group = $licenseGroups[$groupKey]
        $group.Total++
        if (Test-Assigned -item $item) { $group.Assigned++ }
    }

    function Add-CloudSubscriptionProperties {
        param ($item, [string]$prefix)
        $group = $licenseGroups["$(Get-SkuId -item $item)_$($item.team.id)"]
        AddPropertyValue -name "$($prefix)Publisher" -value "JetBrains"
        AddPropertyValue -name "$($prefix)Source" -value $uri
        AddPropertyValue -name "$($prefix)TenantId" -value $group.TeamId
        AddPropertyValue -name "$($prefix)TenantName" -value $group.TeamName
        AddPropertyValue -name "$($prefix)Name" -value $group.ProductName
        AddPropertyValue -name "$($prefix)SkuId" -value $group.SkuId
        AddPropertyValue -name "$($prefix)ObjectId" -value $item.licenseId
        AddPropertyValue -name "$($prefix)Enabled" -value $group.Total
        AddPropertyValue -name "$($prefix)Consumed" -value $group.Assigned
    }

    # One User entity per person (not per license), with one CloudSubscription per
    # assigned license. NewEntity must not be called while an entity is still being
    # populated, so all other entity types are emitted in separate loops.
    $assignedLicenses = @($response | Where-Object { Test-Assigned -item $_ })
    $unassignedLicenses = @($response | Where-Object { -not (Test-Assigned -item $_) })

    $licensesByUser = $assignedLicenses |
        Group-Object { if ($_.assignee.email) { $_.assignee.email } else { $_.assignee.name } } |
        Sort-Object Name

    foreach ($user in $licensesByUser) {
        NewEntity -name "User"
        AddPropertyValue -name "Name" -value $user.Name
        foreach ($item in $user.Group) {
            Add-CloudSubscriptionProperties -item $item -prefix "CloudSubscription."
        }
    }

    # Unassigned licenses have no user to attach to; emit their CloudSubscription as
    # a top-level entity instead so they still show up in LOGINventory.
    foreach ($item in ($unassignedLicenses | Sort-Object licenseId)) {
        NewEntity -name "CloudSubscription"
        Add-CloudSubscriptionProperties -item $item -prefix ""
    }

    # One ProductSubscriptionLicense per individual license (like the JetBrains
    # portal shows them), each with its own expiry date and the licenseId as
    # Number/Gulid. The API does not expose a license key.
    foreach ($item in ($response | Sort-Object licenseId)) {
        NewEntity -name "ProductSubscriptionLicense"
        AddPropertyValue -name "TenantId" -value $item.team.id
        AddPropertyValue -name "TenantName" -value $item.team.name
        AddPropertyValue -name "Name{Editable:true}" -value $item.product.name
        AddPropertyValue -name "Manufacturer{Editable:true}" -value "JetBrains"
        # Gulid = {SkuId}_{TenantId} - LOGINventory uses this to link the license
        # to the product; the licenses themselves stay distinct via Number.
        AddPropertyValue -name "Gulid" -value "$(Get-SkuId -item $item)_$($item.team.id)"
        AddPropertyValue -name "Number{Editable:true}" -value $item.licenseId
        AddPropertyValue -name "Amount{Editable:true}" -value "1"
        AddPropertyValue -name "Multiplicator{Editable:true}" -value "1"
        AddPropertyValue -name "EffectiveAmount{Editable:true}" -value "1"
        AddPropertyValue -name "Method{Editable:true}" -value "2" # equals "Rent"
        AddPropertyValue -name "LicenseType{Editable:true}" -value "0"
        AddPropertyValue -name "Kind{Editable:true}" -value "0"
        if ($item.subscription.validUntilDate) {
            AddPropertyValue -name "End{Editable:true}" -value $item.subscription.validUntilDate.ToString('yyyy-MM-dd')
        }
    }

    Notify -name "Writing Data" -itemName "JetApi" -message $filePath -category "Info" -state "Running"
    WriteInv -filePath $filePath -version $ctx.Version
    Notify -name "Writing Data Done" -itemName "JetApi" -message $filePath -category "Info" -state "Finished" -itemResult "Ok"
}
catch {
    Notify -name "JetApi" -itemName "Error" -message "$_ - $($_.InvocationInfo.ScriptLineNumber)" -category "Error"  -state "Faulty" -itemResult "Error"
}
