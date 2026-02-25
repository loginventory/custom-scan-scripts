<#
.SYNOPSIS
Ein Skript zur Erfassung von Microsoft Intune Geräteinformationen über Microsoft Graph.

.DESCRIPTION
Dieses Skript verwendet Microsoft Graph, um Informationen über Geräte in Microsoft Intune abzurufen. 
Die gesammelten Informationen werden zur Weiterverarbeitung durch den Data Service in eine .inv Datei geschrieben.

.AUTHORS
Tjark-sys & LOGINVENTORY Team

.VERSION
2.0.1

.LICENSE
Dieses Skript ist unter der MIT-Lizenz lizenziert. Vollständige Lizenzinformationen finden Sie unter [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

.NOTES
Das Skript erfordert die Installation der Microsoft.Graph PowerShell-Module und entsprechende Azure AD Berechtigungen:

Insbesondere muss die verwendete App Registration berechtigt sein, Daten zu den in Intune verwalteten Geräten zu lesen.

Dazu muss bei der App Registration unter "API Permissions" eine neue Permission hinzugefügt und mit "Admin Consent granted" werden. Es handelt sich dabei um die "Microsoft Graph Permission", Subtyp "Application permissions", "DeviceManagementManagedDevices.Read.All".

Ist diese Berechtigung nicht vorhanden, erscheint im Job Monitor ein entsprechender Fehler.

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

$scope = Init -encodedParams $parameter
#end of default header ----------------------------------------------------------------------


# Variables for authentication
$tenantId = $scope.Parameters["tenantId"]  # Azure AD Tenant ID
$clientId = $scope.Parameters["clientId"]  # Azure AD App Registration Client ID
$clientSecret = $scope.Parameters["clientSecret"]  # Azure AD App Registration Client Secret
$scanOnlyMobileDevices = $scope.Parameters["scanOnlyMobileDevices"] # Boolean to determine if only mobile devices should be scanned (optional)

# Convert the ClientSecret to a SecureString
$clientSecretSecurePass = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force

# Create credentials
$clientSecretCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $clientId, $clientSecretSecurePass

# Connect to MgGraph
Connect-MgGraph -ClientSecretCredential $clientSecretCredential -TenantId $tenantId -NoWelcome

# Retrieve Intune device information (managed devices)
$devices = Get-MgDeviceManagementManagedDevice -All | Select-Object deviceName, model, manufacturer, operatingSystem, osVersion, userId, imei, wiFiMacAddress, phoneNumber, serialNumber, totalStorageSpaceInBytes, freeStorageSpaceInBytes, enrolledDateTime, DeviceCategoryDisplayName, ManagedDeviceName, SubscriberCarrier

$numberOfMobileDevices = $devices | Where-Object { $_.operatingSystem -in @("iOS", "Android") } | Measure-Object | Select-Object -ExpandProperty Count

$message = "Found $($devices.Count) devices in Intune, of which $numberOfMobileDevices are mobile devices."

if ($scanOnlyMobileDevices -eq "true") {
    $message = "Found $numberOfMobileDevices mobile devices in Intune."
}

# Output the number of devices found to the Job Monitor
Notify -name "Information" -itemName "Evaluation" -itemResult "None" -message $message -category "Info" -state "Detecting"

# Process the data
foreach($device in $devices) {

    # Set ChassisType to "Mobile" for iOS and Android, leave empty for other devices as unknown
    # Use normal DeviceName for PCs, ManagedDeviceName for mobile devices: For smartphones, DeviceName is often "iPhone", which is not unique
    $chassisType = ""
    $name = $device.deviceName
    if ($device.operatingSystem -in @("iOS", "Android")) {
        $chassisType = "Mobile"
        $name = $device.ManagedDeviceName
    }

    # Skip non-mobile devices if "scanOnlyMobileDevices" is true
    if ($scanOnlyMobileDevices -eq "true" -and $chassisType -ne "Mobile") {
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
    AddPropertyValue -name "OperatingSystem.InstallDate" -value $device.enrolledDateTime

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

    # Determine and set the owner of the device
    if ($device.userId -ne $null -and $device.userId -ne "") {
        # Ignore errors if the user no longer exists in Azure AD
        $ownerData = Get-MgUser -UserId $device.userId -Property onPremisesDomainName, onPremisesSamAccountName -ErrorAction SilentlyContinue
        if (($ownerData.onPremisesDomainName -ne $null) -and ($ownerData.onPremisesSamAccountName -ne $null)) {
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
    AddPropertyValue -name "MobileDeviceInfo.MobileOperator" -value $device.SubscriberCarrier

    Notify -name $name -itemName "Inventory" -message $name -category "Info" -state "Finished" -ItemResult "Ok"
}

# Define file name and file path
$fileName = "$($scope.TimeStamp)@Intune.inv"
$filePath = "$($scope.DataDir)\$fileName"

# Generate inventory file and save it in the data directory
WriteInv -filePath "$filePath" -version $scope.Version

# Notify LOGINventory Job Monitor
Notify -name "Writing Data" -itemName "Inventory" -itemResult "Ok" -message "Intune" -category "Info" -state "Finished"

$message = "Found $($devices.Count) devices in Intune, of which $numberOfMobileDevices are mobile devices."

if ($scanOnlyMobileDevices -eq "true") {
    $message = "Found $numberOfMobileDevices mobile devices in Intune."
}

Notify -name "Information" -itemName "Evaluation" -itemResult "Ok" -message $message -category "Info" -state "Finished"