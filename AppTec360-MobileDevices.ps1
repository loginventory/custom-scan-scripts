<#
.SYNOPSIS
Ein Skript zur Erfassung von Smartphones und Tablets in AppTec360 EMM.

.DESCRIPTION
Dieses Skript verwendet die API von AppTec360 EMM, um Informationen von mobilen Geräten abzurufen. 
Die gesammelten Informationen werden zur Weiterverarbeitung für den Data Service in eine .inv Datei geschrieben.

.AUTHOR
Schmidt's LOGIN GmbH

.VERSION
1.0.0

.LICENSE
Dieses Skript ist unter der MIT-Lizenz lizenziert. Vollständige Lizenzinformationen finden Sie unter [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

.NOTES
Zur Ausführung dieses Skripts, ist das Anlegen eines API Keys gemäß der Anleitung von AppTec360 EMM notwendig: https://www.apptec360.com/pdf/AppTec_REST_API_Guide.pdf 

Das Skript benötigt die folgenden Parameter, um korrekt ausgeführt zu werden:

.PARAMETER
Diese Zugangsdaten können Sie im RemoteScanner in der Skriptbasierten Inventarisierung unter Parameter, oder hier direkt verwenden.
- apiUrl (z.B. "https://your-apptec-url/public/external/api")
- apiKey (z.B. "26ahb73n2h3n3k3h38333h33n")
- privateKeyPath (z.B. "C:\temp\PrivateKey.pem") 

Bei der Angabe der Werte im Remote Scanner kann auf die Anführungszeichen verzichtet werden.
#>

#default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)
. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")

$scope = Init -encodedParams $parameter
#end of default header ----------------------------------------------------------------------

# Variablen für Authentifizierung
$apiUrl = $scope.Parameters["apiUrl"]
$apiKey = $scope.Parameters["apiKey"]
$privateKeyPath = $scope.Parameters["privateKeyPath"]

# Zeitstempel in Unix-Zeit
$timeStamp = [Math]::Floor((Get-Date -UFormat %s))

# Funktion zum Signieren der Anfrage
function Sign-Request {
    param (
        [string]$requestData,
        [string]$privateKeyPath
    )
    $privateKey = Get-Content -Path $privateKeyPath -Raw
    $sha512 = New-Object System.Security.Cryptography.SHA512Managed
    $hashBytes = $sha512.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($requestData))
    $cryptoProvider = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $cryptoProvider.ImportFromPem($privateKey)
    $signedBytes = $cryptoProvider.SignHash($hashBytes, "SHA512")
    return [Convert]::ToBase64String($signedBytes)
}

# IDs abrufen
$requestDataGetIDs = @{
    api = "v2/device/listdevices"
    time = $timeStamp
} | ConvertTo-Json -Depth 10

$signatureGetIDs = Sign-Request -requestData $requestDataGetIDs -privateKeyPath $privateKeyPath

$headersGetIDs = @{
    "Content-Type" = "application/json"
    "auth" = $apiKey
    "signature" = $signatureGetIDs
}

$responseGetIDs = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headersGetIDs -Body $requestDataGetIDs

if ($responseGetIDs.errors -and $responseGetIDs.errors.Count -gt 0) {
    Write-Host "Fehler beim Abrufen der IDs: $($responseGetIDs.errors | Out-String)"
    return
}

$deviceIDs = $responseGetIDs.list | ForEach-Object { $_.id }

# Details zu Geräten abrufen
$requestDataGetAssets = @{
    api = "v2/device/getassetdata"
    time = $timeStamp
    params = @{
        ids = $deviceIDs
    }
} | ConvertTo-Json -Depth 10

$signatureGetAssets = Sign-Request -requestData $requestDataGetAssets -privateKeyPath $privateKeyPath

$headersGetAssets = @{
    "Content-Type" = "application/json"
    "auth" = $apiKey
    "signature" = $signatureGetAssets
}

$responseGetAssets = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headersGetAssets -Body $requestDataGetAssets

if ($responseGetAssets.errors -and $responseGetAssets.errors.Count -gt 0) {
    Write-Host "Fehler beim Abrufen der Gerätedaten: $($responseGetAssets.errors | Out-String)"
} else {
    $listCount = ($responseGetAssets.result | Get-Member -MemberType Properties).Count
    # Ausgabe der Anzahl an gefundenen Geräten an den Job Monitor
    Notify -name "Information" -itemName "Auswertung" -itemResult "None" -message "Es wurden $listCount Assets gefunden" -category "Info" -state "Detecting"
}

function Convert-ToUtc {
    param (
        [Parameter(Mandatory = $true)]
        [string]$LocalTimeString,

        [Parameter(Mandatory = $false)]
        [string]$TimeZoneId = [System.TimeZoneInfo]::Local.Id
    )

    try {
        # Parse the local time string into a DateTime object
        $LocalTime = [DateTime]::Parse($LocalTimeString)

        # Get the specified time zone or use the local system's time zone
        $TimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)

        # Convert the local time to UTC
        $UtcTime = [System.TimeZoneInfo]::ConvertTimeToUtc($LocalTime, $TimeZone)

        return $UtcTime
    } catch {
        Write-Error "An error occurred: $_"
    }
}

foreach ($item in $responseGetAssets.result) {
    foreach ($subitem in $item.psobject.Properties) {
        # Neues Gerät Erzeugen
        NewEntity -name "Device"
        # $name wird aus Name und Seriennummer zusammengesetzt, da Name nicht immer eindeutig (z.B. "iPhone")
        $name= $subitem.Value.AT002 + " - " + $subitem.Value.AT005

        # Namen des Gerätes
        AddPropertyValue -name "Name"  -value $name

        # Reaktivieren von archivierten Assets
        AddPropertyValue -name "Archived" -value ""

        # Seriennummer des Gerätes
        AddPropertyValue -name "SerialNumber" -value $subitem.Value.AT005

        # Art des Gerätes
        AddPropertyValue -name "DeviceInfo.ChassisType" -value "Mobile"

        # Modell und Herstellers des Gerätes
        AddPropertyValue -name "HardwareProduct.Name" -value $subitem.Value.AT052
        # Hersteller-Wert meist nicht befüllt
        if ($subitem.Value.AT052 -match "iPhone|iPad") {
            $manufacturer = "Apple"
        } else {
            $manufacturer = $subitem.Value.AT023
        }
        AddPropertyValue -name "HardwareProduct.Manufacturer{Editable:true}" -value $manufacturer

        # Betriebssystem, Version des Geräts
        AddPropertyValue -name "OperatingSystem.Name" -value $subitem.Value.AT031
        AddPropertyValue -name "OperatingSystem.Version" -value $subitem.Value.AT003

        AddPropertyValue -name "MobileDeviceInfo.PhoneNumber"  -value $subitem.Value.AT040
        AddPropertyValue -name "MobileDeviceInfo.DeviceImei"  -value $subitem.Value.AT008
        AddPropertyValue -name "MobileDeviceInfo.MobileOperator" -value $subitem.Value.AT055

        if ($subitem.Value.AT022 -ne $null) {
            AddPropertyValue -name "LastInventory.Mac" -value $subitem.Value.AT022.ToUpper()
        }
        AddPropertyValue -name "LastInventory.Ip" -value $subitem.Value.AT026

        # Letzter Kontakt des Gerätes in UTC-Zeit (dazu sollte vorher eine Eigene Eigenschaft "LastSeen" vom Typ "DateTime" (editierbar durch Scanner)angelegt werden)
        if ($subitem.Value.AT020 -ne $null) {
            $lastseen = Convert-ToUtc -LocalTimeString $subitem.Value.AT020
            AddPropertyValue -name "Custom.LastSeen" -value $lastseen
        }
        # Setzen der Geräte-Zuordnung (Private / Corporate)
        AddPropertyValue -name "Custom.DeviceOwnership" -value $subitem.Value.AT035

        # Speicherplatz des Gerätes             
        if ($subitem.Value.AT006 -ne 0 -and $subitem.Value.AT006 -ne $null) {
            $totalSpace = ([int][regex]::Match($subitem.Value.AT006, '\d+').Value) * 1024
            $freeSpace = ([int][regex]::Match($subitem.Value.AT007, '\d+').Value) * 1024
            $spacePercentage = [math]::Round(($freeSpace / $totalSpace) * 100)
            AddPropertyValue -name "Partition.Name" -value "Main Storage"
            AddPropertyValue -name "Partition.TotalSpace" -value ($totalSpace)
            AddPropertyValue -name "Partition.FreeSpace" -value ($freeSpace)
            AddPropertyValue -name "Partition.FreeSpacePc" -value $spacePercentage
        } 

        # Apps
        foreach ($subobject in $subitem.Value.AT068) {
            foreach($app in $subobject.psobject.Properties) {
                
                AddPropertyValue -name "SoftwarePackage.Name" -value $app.Value.appName
                AddPropertyValue -name "SoftwarePackage.Version" -value $app.Value.version
                AddPropertyValue -name "SoftwarePackage.Platform" -value $subitem.Value.AT031
                AddPropertyValue -name "SoftwarePackage.KeyName" -value $app.Name
            }
        }
        # Schreibt den Owner in Email-Form. Funktioniert nur, wenn in LOGINventory bereits ein User mit dieser Email-Adresse als Name existiert.
        AddPropertyValue -name "Owner.Name" -value $subitem.Value.email

        <#
        #Standort des Geräts
        if ($subitem.Value.AT027 -match 'lat:\s*([\d\.\-]+)\s+lng:\s*([\d\.\-]+)') {
            $latitude = $matches[1]
            $longitude = $matches[2]
        
            # Output the values
            AddPropertyValue -name "Custom.LocationLat" -value $latitude
            AddPropertyValue -name "Custom.LocationLong" -value $longitude
        }
        #>
        Notify -name $name -itemName "Inventarisierung" -message $name -category "Info" -state "Finished"
    }
}
$filePath = "$($scope.DataDir)\apptec$($scope.TimeStamp).inv"
WriteInv -filePath "$filePath" -version $scope.Version