<#
.SYNOPSIS
Ein Skript zur Erfassung von Microsoft Intune Geräteinformationen über Microsoft Graph.

.DESCRIPTION
Dieses Skript verwendet Microsoft Graph, um Informationen über Geräte in Microsoft Intune abzurufen. 
Die gesammelten Informationen werden zur Weiterverarbeitung für LOGINsert in eine .inv Datei geschrieben.

.AUTHOR
Tjark-sys

.VERSION
1.0.0

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
#>

#default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)
. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")

$scope = Init -encodedParams $parameter
#end of default header ----------------------------------------------------------------------


# Variablen für Authentifizierung
$tenantId = $scope.Parameters["tenantId"]  # Azure AD Tenant ID
$clientId = $scope.Parameters["clientId"]  # Azure AD App Registrierungs Client ID
$clientSecret = $scope.Parameters["clientSecret"]  # Azure AD App Registrierungs Client Secret

# Wandel das ClientSecret in einen SecureString um
$clientSecretSecurePass = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force

# Erstelle Anmeldeinformationen
$clientSecretCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $clientId, $clientSecretSecurePass

# Verbinden mit MgGraph
Connect-MgGraph -ClientSecretCredential $clientSecretCredential -TenantId $tenantId -NoWelcome

# Hole Intune Geräteinformationen (managed devices)
$devices = Get-MgDeviceManagementManagedDevice -All | Select-Object deviceName, model, manufacturer, operatingSystem, osVersion, userId, imei, wiFiMacAddress, phoneNumber, serialNumber, totalStorageSpaceInBytes, freeStorageSpaceInBytes, enrolledDateTime

# Ausgabe der Anzahl an gefundenen Geräten an den Job Monitor
Notify -name "Information" -itemName "Auswertung" -itemResult "None" -message "Es wurden $($devices.Count) Assets gefunden" -category "Info" -state "Detecting"

# Einsetzen der Daten
foreach($device in $devices) {
    # Neues Gerät Erzeugen
    NewEntity -name "Device"

    # Namen des Gerätes
    AddPropertyValue -name "Name"  -value $device.deviceName

    # Seriennummer des Gerätes
    AddPropertyValue -name "SerialNumber" -value $device.serialNumber

    # Art des Gerätes
    AddPropertyValue -name "DeviceInfo.ChassisType" -value "Mobile"

    # Modell und Herstellers des Gerätes
    AddPropertyValue -name "HardwareProduct.Manufacturer{Editable:true}" -value $device.manufacturer
    AddPropertyValue -name "HardwareProduct.Name" -value $device.model

    # Betriebssystem, Version und Installationsdatum des Gerätes
    AddPropertyValue -name "OperatingSystem.Name" -value $device.operatingSystem
    AddPropertyValue -name "OperatingSystem.Version" -value $device.osVersion
    AddPropertyValue -name "OperatingSystem.InstallDate" -value $device.enrolledDateTime

    # Speicherplatz des Gerätes
    $totalSpace = ([double]$device.totalStorageSpaceInBytes) / 1048576
    $freeSpace = ([double]$device.freeStorageSpaceInBytes) / 1048576
    $spacePercentage = [math]::Round(($freeSpace / $totalSpace) *100)
    AddPropertyValue -name "Partition.Name" -value "Main Storage"
    AddPropertyValue -name "Partition.TotalSpace" -value $totalSpace
    AddPropertyValue -name "Partition.FreeSpace" -value $freeSpace
    AddPropertyValue -name "Partition.FreeSpacePc" -value $spacePercentage

    # Besitzer des Gerätes ermitteln und setzen
    $ownerData = Get-MgUser -UserId $device.userId -Property onPremisesDomainName, onPremisesSamAccountName
    if(($ownerData.onPremisesDomainName -ne $null) -and ($ownerData.onPremisesSamAccountName -ne $null)) {
        AddPropertyValue -name "Owner.Name" -value "$($ownerData.onPremisesDomainName)\$($ownerData.onPremisesSamAccountName)"
    }

    # Mac Adresse des Gerätes
    $fromattedMac = ($device.wiFiMacAddress -replace "..", '$&:').TrimEnd(':').ToUpper()
    AddPropertyValue -name "LastInventory.Mac" -value $fromattedMac

    # IMEI des Gerätes
    AddPropertyValue -name "MobileDeviceInfo.DeviceImei" -value $device.imei

    # Telefonnummer des Gerätes
    AddPropertyValue -name "MobileDeviceInfo.PhoneNumber" -value $device.phoneNumber

    # Dateinamen und Dateipfad definieren
    $fileName = "$($scope.TimeStamp)@$($device.deviceName -replace '[\\/:*?"<>|]', '').inv"
    $filePath = "$($scope.DataDir)\$fileName"

    # LOGINventory Job Monitor Benachrichtigen
    Notify -name "Schreibe Daten..." -itemName "Inventarisierung" -message $device.deviceName -category "Info" -state "Calculating" 

    # Inventar Datei erzeugen und ablegen im Datenverzeichnis
    WriteInv -filePath "$filePath" -version $scope.Version

    # LOGINventory Job Monitor Benachrichtigen
    Notify -name "Schreiben abgeschlossen!" -itemName "Inventarisierung" -message $device.deviceName -category "Info" -state "Finished"
}
