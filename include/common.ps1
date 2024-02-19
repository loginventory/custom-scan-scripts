#reserved variables 
$lBaseEntity = ""
$lItems = New-Object System.Collections.ArrayList
$lEntries = New-Object System.Collections.ArrayList

function Decode() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$value
    )    
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($value))
}

function Init {
    [CmdletBinding()]
    param (
        [string]$encodedParams = ""
    )
        
        $decodedParams = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encodedParams))
        $paramPairs = $decodedParams -split ';'
    
        foreach ($pair in $paramPairs) {
            $keyValue = $pair -split ','
            $key = $keyValue[0]
            $value = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($keyValue[1]))
    
            switch ($key) {
                'dataDir' { $dataDir = $value }
                'version' { $version = $value }
                'params' { $parameters = $value }
                'credentials' { $credentials = $value }
                default { Write-Warning "Unkown Key: $key" }
            }
        }

    try {
        if (![string]::IsNullOrWhiteSpace($credentials)) {                
            $jsonString = $credentials
            $c = $jsonString | ConvertFrom-Json 
        }
        else{
            Write-Host "no credentials"
        }

        if (![string]::IsNullOrWhiteSpace($parameters)) {
            $value = $parameters
            $p = @{}            
            $value.TrimStart('@{').TrimEnd('}').Split(';').ForEach({
                    if ($_ -ne '') {
                        $keyValue = $_.Split('=')
                        $p[$keyValue[0]] = $keyValue[1]
                    }
                })
        }
        return [PSCustomObject]@{
            Credentials = $c
            Parameters  = $p
            DataDir     = $dataDir
            Version     = $version
            TimeStamp   = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
            TimeStamp2  = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        }
    }
    catch {
        Write-Error "Failed to process input: $_"
    }
}



function Notify() {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$itemName,
        [string]$name,
        [Parameter(Mandatory = $true)]
        [string]$message,
        [string]$category,
        [string]$state,
        [string]$info
    )

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $itemName
    }

    Write-Host "ItemEvent: Category: $($category) | Name: $($name) | ItemName: $($itemName) | Message: $($message) | State: $($state) | Info: $($info)"
}

function GetAllPropertyValuesAsString {
    param (
        [Parameter(Mandatory = $true)]
        $object
    )

    $propertyValues = @()

    $object | Get-Member -MemberType Properties | ForEach-Object {
        $propertyName = $_.Name
        $propertyValue = $object.$propertyName
        $propertyValues += "$($propertyName): $propertyValue"
    }

    $resultString = $propertyValues -join ", "
    return $resultString
}

function ConvertTo-Xml {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.ArrayList]$elements       
    )

    $stringWriter = New-Object System.IO.StringWriter
    $xmlWriter = New-Object System.Xml.XmlTextWriter($stringWriter)
    $xmlWriter.Formatting = 'Indented'

    $xmlWriter.WriteStartDocument()
    $xmlWriter.WriteStartElement("root")

    foreach ($element in $elements) {
        $xmlWriter.WriteStartElement($script:lBaseEntity)
        $firstPropertyName = $null
        $currentParent = $null

        foreach ($entry in $element) {
            $parts = $entry -split '=', 2
            $hierarchy = $parts[0].Trim() -split '\.'
            $value = $parts[1].Trim()

            if($hierarchy.Length -eq 1) {
                #do not encupsulate single properties
                $xmlWriter.WriteElementString($hierarchy[0], $value)
                continue
            }

            $currentSubentryName = $hierarchy[0]
            $propertyName = $hierarchy[-1]

            if ($propertyName -eq $firstPropertyName -or $currentParent -ne $currentSubentryName) {
                if ($currentParent) {
                    $xmlWriter.WriteEndElement()
                }
                $firstPropertyName = $propertyName
                $xmlWriter.WriteStartElement($currentSubentryName)
            }

            $currentParent = $currentSubentryName
            $xmlWriter.WriteElementString($propertyName, $value)
        }

        if ($currentParent) {
            $xmlWriter.WriteEndElement()
        }
        $xmlWriter.WriteEndElement()
    }

    $xmlWriter.WriteEndElement()
    $xmlWriter.WriteEndDocument()
    $xmlWriter.Flush()

    return $stringWriter.ToString()
}



function PostProcessXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$xml,
        [Parameter(Mandatory = $true)]
        [string]$version
    )
       
    $scriptName = $MyInvocation.MyCommand.Name
    $loginfoNamespaceVersion = ($version -split '\.')[0] + ".0"

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $xmlDocument = New-Object System.Xml.XmlDocument
    $xmlDocument.LoadXml($xml)
    $newXmlDocument = New-Object System.Xml.XmlDocument

    $newRoot = $newXmlDocument.CreateElement("Inventory")
    $newRoot.SetAttribute("xmlns", "http://www.loginventory.com/schemas/LOGINventory/data")
    $newRoot.SetAttribute("Version", $Version)
    $newRoot.SetAttribute("Agent", $scriptName)
    $newRoot.SetAttribute("Timestamp", $timestamp)

    foreach ($node in $xmlDocument.DocumentElement.ChildNodes) {
        $importedNode = $newXmlDocument.ImportNode($node, $true)    
        if ($importedNode.LocalName -eq $script:lBaseEntity) {
            $importedNode.SetAttribute("xmlns", "http://www.loginventory.com/schemas/LOGINventory/data/$loginfoNamespaceVersion/LogInfo")
        }
        $newRoot.AppendChild($importedNode) | Out-Null
    }

    $newXmlDocument.AppendChild($newRoot) | Out-Null
    return $newXmlDocument.OuterXml
}

function SetEntityName {
    param (
        [Parameter(Mandatory = $true)]
        [string]$name
    )
    if($script:lBaseEntity -ne "") {
        throw "Entity $lBaseEntity not closed"
    }
    $script:lBaseEntity = $name
}

function NewEntity {
    if($script:lEntries.Count -gt 0) {        
        $script:lItems.Add($script:lEntries.Clone()) | Out-Null     
        $script:lEntries = New-Object System.Collections.ArrayList
    }    
}

function AddPropertyValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$name,
        [string]$value = "-"
    )
    if($script:lBaseEntity -eq "") {
        throw "No entity started, use SetEntityName first"
    }    
    $script:lEntries.Add("$name = $value") | Out-Null
}

function Finalize {
    NewEntity    
}

function WriteInv {
    param (
        [Parameter(Mandatory = $true)]
        [string]$filePath,

        [Parameter(Mandatory = $true)]        
        [string]$version
    )

    Finalize
    $tmp = $script:lItems.Clone()               
    $itemXml = ConvertTo-Xml -elements $tmp               
    $mxl = PostProcessXml -Xml $itemXml -version $version
    $mxl | Out-File -FilePath $filePath 
    $script:lItems.Clear() | Out-Null;
    $script:lEntries.Clear() | Out-Null;
}
