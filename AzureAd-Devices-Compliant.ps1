<#
.SYNOPSIS
Ein Skript zur Erfassung von Azure AD Geräteinformationen über Microsoft Graph.

.DESCRIPTION
Dieses Skript verwendet Microsoft Graph, um Informationen über Geräte in Azure Active Directory abzurufen. Es liest unter anderem den Compliant Status der Geräte aus und erzeugt für diesen eine Eigene Eigenschaft (Compliant), welche dann in LOGINventory zur Verfügung steht.
Die gesammelten Informationen werden zur Weiterverarbeitung für LOGINsert in eine .inv Datei geschrieben.

.AUTHOR
Schmidt's LOGIN GmbH - [www.loginventory.de](https://www.loginventory.de)

.VERSION
1.0.0

.LICENSE
Dieses Skript ist unter der MIT-Lizenz lizenziert. Vollständige Lizenzinformationen finden Sie unter [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

.NOTES
Das Skript erfordert die Installation der Microsoft.Graph PowerShell-Module und entsprechende Azure AD Berechtigungen.
Diese Zugangsdaten können Sie dann im RemoteScanner in der Skriptbasierten Inventarisierung unter Parameter tenantId, clientId und clientSecret hinterlegen, oder hier direkt verwenden.

.PARAMETER
Diese Zugangsdaten können Sie im RemoteScanner in der Skriptbasierten Inventarisierung unter Parameter, oder hier direkt verwenden.
- tenantId
- clientId
- clientSecret
- nameFilter (optional, z.B. mit name* können Sie die Geräte filtern, die in die .inv Datei aufgenommen werden sollen, wobei * ein Wildcard ist.)
#>

#default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)

. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")

$scope = Init -encodedParams $parameter
#end of default header ----------------------------------------------------------------------

$filePath = "$($scope.DataDir)\azure-$($scope.TimeStamp).inv"

# Required Modules
#Install-Module -Name Microsoft.Graph
#Install-Module -Name Microsoft.Graph.Authentication
#Install-Module -Name Microsoft.Graph.Users

$namefilter = $scope.Parameters["namefilter"];

$TenantId = $scope.Parameters["tenantId"]
$ClientId = $scope.Parameters["clientId"]
$ClientSecret = $scope.Parameters["clientSecret"]

$securePassword = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
$pscredential = New-Object System.Management.Automation.PSCredential ($ClientId, $securePassword)

Notify -name "Connect" -itemName "MSGRAPH" -message "Connecting-Tenant: $($TenantId)" -category "Info"  -state "Running"  
Connect-MgGraph -ClientSecretCredential $pscredential -TenantId $TenantId
Notify -name "Connected" -itemName "MSGRAPH" -message "Ok" -category "Info" -state "Finished"

Notify -name "Getting Devices" -itemName "MSGRAPH" -message "..." -category "Info" -state "None"

$devices = Get-MgDevice -All

#$devices | Format-List -Property * | Out-File -FilePath "c:\temp\devices-and-all-properties.txt"

Notify -name "Getting Devices Done" -itemName "MSGRAPH" -message "Found $($devices.Count) Devices" -category "Info" -state "None"
    
try {
    foreach ($device in $devices) {                        
        if ($namefilter -and $device.DisplayName -notlike $namefilter) {
            continue
        }

        Notify -name $device.DisplayName -itemName "MSGRAPH" -message "Device: $($device.DisplayName) Compliant: $($device.IsCompliant)" -category "Info"  -state "Finished"                  

        $compliantValue = if ($null -eq $device.IsCompliant) { "n/v" } else { $device.IsCompliant }
        
        NewEntity -name "Device"
        AddPropertyValue -name "Name" -value $device.DisplayName
        AddPropertyValue -name "Custom.Compliant" -value $compliantValue
        AddPropertyValue -name "LastInventory.Timestamp" -value $scope.TimeStamp2
        AddPropertyValue -name "OperatingSystem.Name" -value $($device.OperatingSystem)
        AddPropertyValue -name "OperatingSystem.Version" -value $($device.OperatingSystemVersion)
        foreach ($subdevice in $device.SoftwarePackages) {
            AddPropertyValue -name "SoftwarePackage.Name" -value $($subEntry.Name)
            AddPropertyValue -name "SoftwarePackage.Path" -value $($subEntry.Path)
        }            
    }
    
    Notify -name "Writing Data" -itemName "MSGRAPH" -message $filePath -category "Info" -state "None"        
    WriteInv -filePath $filePath -version $scope.Version
    Notify -name "Writing Data Done" -itemName "MSGRAPH" -message $filePath -category "Info" -state "Finished"
}
catch {
    Notify -name "ERROR" -itemName "Error" -message "$_ - $($_.InvocationInfo.ScriptLineNumber)" -category "Error"  -state "Faulty" -itemResult "Error"
}

Disconnect-MgGraph
