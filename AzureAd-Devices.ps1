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

SetEntityName -name "Device"

foreach ($credential in $scope.Credentials) {
    $TenantId = $credential.TenantId
    $ClientId = $credential.ClientId
    $ClientSecret = Decode -value $credential.Secret

    $securePassword = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
    $pscredential = New-Object System.Management.Automation.PSCredential ($ClientId, $securePassword)

    Notify -name "Connect" -itemName "MSGRAPH" -message "Connecting-Tenant: $($TenantId)" -category "Info"  -state "Running"  
    Connect-MgGraph -ClientSecretCredential $pscredential -TenantId $TenantId
    Notify -name "Connected" -itemName "MSGRAPH" -message "Ok" -category "Info" -state "Finished"

    Notify -name "Getting Devices" -itemName "MSGRAPH" -message "..." -category "Info" -state "None"

    $devices = Get-MgDevice -All
    Notify -name "Getting Devices Done" -itemName "MSGRAPH" -message "Found $($devices.Count) Devices" -category "Info" -state "None"
        
    try {
        foreach ($device in $devices) {                        
            if ($namefilter -and $device.DisplayName -notlike $namefilter) {
                continue
            }

            Notify -name $device.DisplayName -itemName "MSGRAPH" -message "Device: $($device.DisplayName)" -category "Info"  -state "Finished"          
            
            NewEntity
            AddPropertyValue -name "Name" -value $device.DisplayName
            
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
        Notify -name "ERROR" -itemName "Error" -message "$_ - $($_.InvocationInfo.ScriptLineNumber)" -category "Error"  -state "Faulty"
    }

    Disconnect-MgGraph

}