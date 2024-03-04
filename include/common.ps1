#reserved variables 
$lEntities = New-Object System.Collections.ArrayList

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
            default { Write-Warning "Unkown Key: $key" }
        }
    }

    try {
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
        [string]$info,
        [int]$resultCode,
        [string]$itemResult
    )

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $itemName
    }

    Write-Host "ItemEvent: Category: $($category) | Name: $($name) | ItemName: $($itemName) | Message: $($message) | State: $($state) | Info: $($info) | ResultCode: $($result) | ItemResult: $($itemResult)"
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
        $version
    )

    $loginfoNamespaceVersion = ($version -split '\.')[0] + ".0"

    $xmlWriterSettings = New-Object System.Xml.XmlWriterSettings
    $xmlWriterSettings.Indent = $true
    $xmlWriterSettings.OmitXmlDeclaration = $true

    $stringBuilder = New-Object System.Text.StringBuilder
    $xmlWriter = [System.Xml.XmlWriter]::Create($stringBuilder, $xmlWriterSettings)

    $attributePattern = '\{(.+?):(.+?)\}'
    try {   
        $xmlWriter.WriteStartDocument()
        $xmlWriter.WriteStartElement('root')

        foreach ($item in $Script:lEntities) {

            $xmlWriter.WriteStartElement($item.Name, "http://www.loginventory.com/schemas/LOGINventory/data/$loginfoNamespaceVersion/LogInfo")            

            $previousKeyPrefix = $null

            foreach ($entry in $item.Entries) {
                $attributePattern = '\{(.+?)\}'
                $parts = $entry -split '=', 2
                $key = $parts[0].Trim() -replace $attributePattern, ''
                $value = $parts[1].Trim()
                $keyPath = $key.Split('.')
                $matches = [regex]::Matches($parts[0], $attributePattern)
    
                if ($keyPath.Count -eq 1) {
                    $element = $xmlWriter.WriteStartElement($key)
                    foreach ($match in $matches) {
                        $attributes = $match.Groups[1].Value -split ';'
                        foreach ($attribute in $attributes) {
                            $attrParts = $attribute -split ':'
                            if ($attrParts.Count -eq 2) {
                                $xmlWriter.WriteAttributeString($attrParts[0], $attrParts[1])
                            }
                        }
                    }
                    $xmlWriter.WriteString($value)
                    $xmlWriter.WriteEndElement()
                    continue
                }
    
                $keyPrefix = $keyPath[0]
    
                if ($keyPrefix -ne $previousKeyPrefix -or ($keyPrefix -eq 'SoftwarePackage' -and $keyPath[1] -eq 'Name')) {
                    if ($previousKeyPrefix) {
                        $xmlWriter.WriteEndElement()
                    }
                    $xmlWriter.WriteStartElement($keyPrefix)
                }
    
                $previousKeyPrefix = $keyPrefix
    
                if ($keyPath.Count -gt 1) {
                    $element = $xmlWriter.WriteStartElement($keyPath[1])
                    foreach ($match in $matches) {
                        $attributes = $match.Groups[1].Value -split ';'
                        foreach ($attribute in $attributes) {
                            $attrParts = $attribute -split ':'
                            if ($attrParts.Count -eq 2) {
                                $xmlWriter.WriteAttributeString($attrParts[0], $attrParts[1])
                            }
                        }
                    }
                    $xmlWriter.WriteString($value)
                    $xmlWriter.WriteEndElement()
                }
            }


            if ($previousKeyPrefix) {
                $xmlWriter.WriteEndElement()
            }
    
            $xmlWriter.WriteEndElement()
        }
    

        $xmlWriter.WriteEndElement()
        $xmlWriter.WriteEndDocument()
        $xmlWriter.Flush()
        $xmlWriter.Close()
    }
    catch {
        Write-Host "$_ - $($_.InvocationInfo.ScriptLineNumber)"
    }
    return $stringBuilder.ToString()
}


function ConvertTo-Xml2 {
    param (
        [Parameter(Mandatory = $true)]
        $version
    )
    $stringWriter = New-Object System.IO.StringWriter
    $xmlWriter = New-Object System.Xml.XmlTextWriter($stringWriter)
    $xmlWriter.Formatting = 'Indented'

    $xmlWriter.WriteStartDocument()
    $xmlWriter.WriteStartElement("root")

    $loginfoNamespaceVersion = ($version -split '\.')[0] + ".0"
    try {
        foreach ($entity in $Script:lEntities) {
            $xmlWriter.WriteStartElement($entity.Name, "http://www.loginventory.com/schemas/LOGINventory/data/$loginfoNamespaceVersion/LogInfo")
            
            foreach ($entityEntry in $entity.Entries) {                
                $firstPropertyName = $null
                $currentParent = $null

                foreach ($entry in $entityEntry) {
                    $parts = $entry -split '=', 2
                    $hierarchy = $parts[0].Trim() -split '\.'
                    $value = $parts[1].Trim()

                    if ($hierarchy.Length -eq 1) {
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
            }
            $xmlWriter.WriteEndElement()
        }

    }
    catch {
        Notify -name "ERROR" -itemName "Error" -message "$_ - $($_.InvocationInfo.ScriptLineNumber)" -category "Error"  -state "Faulty"
    }
    $xmlWriter.WriteEndElement()
    $xmlWriter.WriteEndDocument()
    $xmlWriter.Flush()

    return $stringWriter.ToString()
}



function PostProcessXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$xml
    )
       
    $scriptName = $MyInvocation.MyCommand.Name

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
        $newRoot.AppendChild($importedNode) | Out-Null
    }

    $newXmlDocument.AppendChild($newRoot) | Out-Null
    return $newXmlDocument.OuterXml
}

function GetCurrentEntity {
    return $script:lEntities[-1]    
}

function NewEntity {
    param (
        [Parameter(Mandatory = $true)]
        [string]$name
    )

    $current = [PSCustomObject]@{
        Name    = $name
        Entries = New-Object System.Collections.ArrayList
    }    
    $script:lEntities.Add($current) | Out-Null
}

function AddPropertyValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$name,
        [string]$value = "-"
    )
    $c = GetCurrentEntity
    $c.Entries.Add("$name = $value") | Out-Null
}

function WriteInv {
    param (
        [Parameter(Mandatory = $true)]
        [string]$filePath,

        [Parameter(Mandatory = $true)]        
        [string]$version
    )

    $itemXml = ConvertTo-Xml -version $version
    $mxl = PostProcessXml -Xml $itemXml
    $mxl | Out-File -FilePath $filePath 
    $lEntities.Clear() | Out-Null
}
