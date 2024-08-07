<#
.SYNOPSIS
Ein Skript zum Einlesen von Informationen zu Benutzern aus CSV-Dateien.

.DESCRIPTION
Dieses Skript öffnet liest aus einer csv-Datei Informationen zu vorhandenen Usern und legt diese in LOGINventory an.
Dazu müssen die Spalten so benannt sein, wie sie in LOGINventory in der Tabelle "UserAccount" heißen, also z.B. "Name", "DisplayName", "FirstName", "Department", "MobilePhone", "BusinessPhone",...

Wichtig: Jeder User benötigt eine eindeutige "ObjectSID" und das Feld "Name"! Diese müssen in der csv-Datei für jeden User enthalten sein. Falls in der Realität keine ObjectSIDs vorhanden sind, kann eine fortlaufende Nummer verwendet werden. Es muss jedoch auf die Eindeutigkeit geachtet werden, da sich die Einträge ansonsten überschreiben.

Eine Spaltentrennung in der csv-Datei erfolgt mittels ";"-Zeichen.

Die gesammelten Informationen werden zur Weiterverarbeitung für den Data Service in eine .inv Datei geschrieben.

Beispiel-Daten:

Name;UserName;FirstName;LastName;DisplayName;Domain;Mail;ObjectSID;Department
John Doe;jdoe;John;Doe;John D;example.com;jdoe@example.com;S-1-5-21-1001;
Jane Smith;jsmith;Jane;Smith;Jane S;example.com;jsmith@example.com;S-1-5-21-1002;IT
Emily Johnson;ejohnson;Emily;Johnson;Emily J;example.com;ejohnson@example.com;S-1-5-21-1003;Administration
Michael Brown;mbrown;Michael;Brown;Michael B;example.com;mbrown@example.com;S-1-5-21-1004;Dev
Sarah Davis;sdavis;Sarah;Davis;Sarah D;example.com;sdavis@example.com;S-1-5-21-1005;Sales

Minimal benötigte Beispiel-Daten:

Name;ObjectSID
John Doe;S-1-5-21-1001
Jane Smith;S-1-5-21-1002

.AUTHOR
Schmidt's LOGIN GmbH - [www.loginventory.de](https://www.loginventory.de)

.VERSION
1.0.0

.LICENSE
Dieses Skript ist unter der MIT-Lizenz lizenziert. Vollständige Lizenzinformationen finden Sie unter [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

.NOTES

.PARAMETER
Das Skript benötigt folgende Parameter (Angabe im Remote Scanner bei der Definition im Reiter "Parameter"):

- pathCSV: Angabe des Pfads ohne zusätzliche Anführungsstriche, also z.B. C:\temp\myUsers.csv

#>

#default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)

. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")

$scope = Init -encodedParams $parameter
#end of default header ----------------------------------------------------------------------

$filePath = "$($scope.DataDir)\userimport-$($scope.TimeStamp).inv"

# Path to the CSV file
$csvPath = $scope.Parameters["pathCSV"]

# Import the CSV file and store it in a variable
$users = Import-Csv -Path $csvPath -Delimiter ';'
$count = $users.Length
Notify -name "Reading csv file" -message "$($count) Users found" -itemName "$($csvPath)" -category "Info" -state "Finished" -itemResult "Ok"

$countAddedUsers=0
try {
    foreach ($user in $users) {
        # Write all "UserAccount" properties
        if ([string]::IsNullOrWhiteSpace($user.ObjectSID)){
            Notify -name $user.DisplayName -itemName "CSV" -message "User $($user.DisplayName) does not have a valid ObjectSID and will not be entered into LOGINventory." -category "Error"  -state "Faulty" -itemResult "Error"             
        }
        elseif ([string]::IsNullOrWhiteSpace($user.Name)){
            Notify -name $user.DisplayName -itemName "CSV" -message "User $($user.DisplayName) does not have a valid Name property and will not be entered into LOGINventory." -category "Error"  -state "Faulty" -itemResult "Error"
        }
        else {
        NewEntity -name "UserAccount"
        AddPropertyValue -name "Name" -value $user.Name
        AddPropertyValue -name "UserName" -value $user.UserName
        AddPropertyValue -name "FirstName" -value $user.FirstName
        AddPropertyValue -name "LastName" -value $user.LastName
        AddPropertyValue -name "DisplayName" -value $user.DisplayName
        AddPropertyValue -name "FullName" -value $user.FullName
        AddPropertyValue -name "OU" -value $user.OU
        AddPropertyValue -name "Department" -value $user.Department
        AddPropertyValue -name "Company" -value $user.Company
        AddPropertyValue -name "Office" -value $user.Office
        AddPropertyValue -name "JobTitle" -value $user.JobTitle
        AddPropertyValue -name "Description" -value $user.Description
        AddPropertyValue -name "Mail" -value $user.Mail
        AddPropertyValue -name "ManagerName" -value $user.ManagerName
        AddPropertyValue -name "BusinessPhone" -value $user.BusinessPhone
        AddPropertyValue -name "MobilePhone" -value $user.MobilePhone
        AddPropertyValue -name "HomePhone" -value $user.HomePhone
        AddPropertyValue -name "EmployeeId" -value $user.EmployeeId
        AddPropertyValue -name "EmployeeType" -value $user.EmployeeType
        AddPropertyValue -name "EmployeeNumber" -value $user.EmployeeNumber
        AddPropertyValue -name "Domain" -value $user.Domain
        AddPropertyValue -name "PrincipalName" -value $user.PrincipalName
        AddPropertyValue -name "ObjectSID" -value $user.ObjectSID
        # Write also "User" properties
        NewEntity -name "User"
        AddPropertyValue -name "Name" -value $user.Name 
        Notify -name "$($user.Name) ($($user.ObjectSID))" -itemName "CSV" -message "User: $($user.Name)" -category "Info"  -state "Finished" -itemResult "Ok"
        $countAddedUsers +=1
        }
    }
    if ($countAddedUsers -gt 0){
        Notify -name "Writing Data" -itemName "CSV" -message $filePath -category "Info" -state "None" -itemResult "Ok"        
        WriteInv -filePath $filePath -version $scope.Version
        Notify -name "Writing Data Done" -itemName "CSV" -message $filePath -category "Info" -state "Finished" -itemResult "Ok"
    }
}      
catch {
    Notify -name "ERROR" -itemName "Error" -message "$_ - $($_.InvocationInfo.ScriptLineNumber)" -category "Error"  -state "Faulty" -itemResult "Error"
}