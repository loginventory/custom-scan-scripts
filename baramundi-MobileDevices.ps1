<#
.SYNOPSIS
Ein Skript zur Erfassung von Smartphones und Tablets in baramundi.

.DESCRIPTION
Dieses Skript verwendet die API von bConnect von baramundi, um Informationen von mobilen Geräten abzurufen. 
Die gesammelten Informationen werden zur Weiterverarbeitung für den Data Service in eine .inv Datei geschrieben.

.AUTHOR
Schmidt's LOGIN GmbH

.VERSION
1.0.0

.LICENSE
Dieses Skript ist unter der MIT-Lizenz lizenziert. Vollständige Lizenzinformationen finden Sie unter [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

.NOTES
Zur Ausführung dieses Skripts, ist das Anlegen eines API Keys gemäß der Anleitung von baramundi erforderlich: https://docs.baramundi.com/helpsetid=m_t_configuration&externalid=i_configuration_interfaces_bConnect.

Das Skript benötigt die folgenden Parameter, um korrekt ausgeführt zu werden:

.PARAMETER
Diese Zugangsdaten können Sie im RemoteScanner in der Skriptbasierten Inventarisierung unter Parameter, oder hier direkt verwenden.
- apiUrl (z.B. "https://SERVERNAME/bconnect/endpoints")
- apiKey (z.B. "26ahb73n2h3n3k3h38333h33n")

Bei der Angabe der Werte im Remote Scanner kann auf die Anführungszeichen verzichtet werden.
#>

#default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)
. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")

$scope = Init -encodedParams $parameter
#end of default header ----------------------------------------------------------------------

# Variables for authentication
$apiUrl = $scope.Parameters["apiUrl"]
$apiKey = $scope.Parameters["apiKey"]

# Build the headers hashtable
$headers = @{
    "X-API-Key" = $apiKey
}

function Get-AndProcess-EndpointData {
    param (
        [string]$endpointType
    )

    # Initialize an empty array to store all items
    $allItems = @()

    # Set the initial page number
    $pageNumber = 1

    # Construct the base URL for the API
    $baseUrl = $apiUrl + "/v2.0/$endpointType"

    do {
        # Construct the URL with the current page number
        $currentUrl = $baseUrl + "?page=" + $pageNumber

        # Make the GET request
        $response = Invoke-RestMethod -Uri $currentUrl -Method Get -Headers $headers

        # Add the current page's data to the $allItems array
        $allItems += $response.data

        # Check if there is another page
        $hasNextPage = $response.hasNextPage

        # Increment the page number for the next request
        $pageNumber++

    } while ($hasNextPage)

    # Process all items in the $allItems array
    foreach ($item in $allItems) {
        # Create a new device entity
        NewEntity -name "Device"
        
        # Device name
        AddPropertyValue -name "Name" -value $item.displayName

        # Reactivate archived assets
        AddPropertyValue -name "Archived" -value ""

        # Serial number of the device
        AddPropertyValue -name "SerialNumber" -value $item.serialNumber

        # Type of device
        AddPropertyValue -name "DeviceInfo.ChassisType" -value "Mobile"

        # Description of the device
        AddPropertyValue -name "DeviceInfo.Description" -value $item.comment

        # Model and manufacturer of the device
        AddPropertyValue -name "HardwareProduct.Name" -value $item.modelName

        AddPropertyValue -name "HardwareProduct.Manufacturer{Editable:true}" -value $item.manufacturer

        # Operating system and version of the device
        AddPropertyValue -name "OperatingSystem.Name" -value $item.operatingSystem
        AddPropertyValue -name "OperatingSystem.Version" -value $item.osVersionString
    
        AddPropertyValue -name "LastInventory.Mac" -value $item.primaryMAC
        AddPropertyValue -name "LastInventory.Ip" -value $item.primaryIP

        AddPropertyValue -name "Custom.LastSeen" -value $item.lastSeen

        # iOS specific properties
        AddPropertyValue -name "Custom.AppleManagementMode" -value $item.appleManagementMode
        AddPropertyValue -name "Custom.AppleDEP" -value $item.appleDEP
        AddPropertyValue -name "Custom.Supervised" -value $item.supervised
        AddPropertyValue -name "Custom.Owner" -value $item.owner
        AddPropertyValue -name "Custom.ManagementState" -value $item.managementState

        # Android specific properties
        AddPropertyValue -name "Custom.AndroidEnterpriseProfileType" -value $item.androidEnterpriseProfileType
        if ($item.cpu.name) {
            AddPropertyValue -name "Cpu.Name" -value $item.cpu.name
            AddPropertyValue -name "Cpu.Type" -value $item.cpu.manufacturer
            AddPropertyValue -name "Cpu.Cores" -value $item.cpu.cores
            $cpuSpeed = $item.cpu.frequency / 1000000
            AddPropertyValue -name "Cpu.Speed" -value $cpuSpeed
        }
        
        Notify -name $item.displayName -itemName "Inventarisierung" -message $item.displayName -category "Info" -state "Finished"
    }
}

# Call the function for both endpoints
Get-AndProcess-EndpointData -endpointType "IosEndpoints"
Get-AndProcess-EndpointData -endpointType "AndroidEndpoints"

$filePath = "$($scope.DataDir)\baramundi$($scope.TimeStamp).inv"
WriteInv -filePath "$filePath" -version $scope.Version
