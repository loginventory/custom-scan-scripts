<#
.SYNOPSIS
Ein Skript zur Erfassung von FortiGate Firewalls, FortiSwitches und FortiAP Access Points über die FortiManager JSON-RPC API.

.DESCRIPTION
Dieses Skript liest über die JSON-RPC API eines FortiManagers alle verwalteten FortiGates aus und fragt über den
FortiManager (/sys/proxy/json) bei jeder FortiGate die per FortiLink verwalteten FortiSwitches und FortiAPs ab.
Jedes physische Gerät wird als eigenständiges Asset in LOGINventory angelegt bzw. aktualisiert:

  - FortiGate          -> Gehäusetyp "Firewall"
                          bei HA-Clustern: ein Asset je Cluster-Mitglied (jedes Mitglied hat eine eigene Seriennummer)
  - FortiSwitch        -> Gehäusetyp "Switch"
  - FortiAP            -> Gehäusetyp "Access Point"

Die Wiedererkennung erfolgt standardmäßig über das LOGINventory Fingerprint-Verfahren (Name, Seriennummer, MAC-Adresse).
So werden auch Geräte zugeordnet, die bereits auf anderem Weg (z.B. per SNMP) erfasst wurden.
Optional (Parameter useSerialAsCustomId) wird die Seriennummer zusätzlich als CustomId geschrieben. Die CustomId ist ein
exklusives Identifikationsmerkmal und setzt das Fingerprint-Verfahren für diese Assets außer Kraft.

Zusätzliche Informationen werden als Eigene Eigenschaften (Custom.*) abgelegt, z.B. übergeordnete FortiGate,
ADOM, HA-Cluster und HA-Rolle, Verbindungsstatus, Firmware-Build.

Die gesammelten Informationen werden zur Weiterverarbeitung durch den Data Service in eine .inv Datei geschrieben.

.AUTHOR
Schmidt's LOGIN GmbH

.VERSION
0.9.0 (Entwurf)

.LICENSE
Dieses Skript ist unter der MIT-Lizenz lizenziert. Vollständige Lizenzinformationen finden Sie unter [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

.NOTES
Voraussetzungen im FortiManager:

  Empfohlen (ab FortiManager 7.2.2): ein REST-API-Administrator mit API-Schlüssel.
      config system admin user
          edit loginventory_api
              set user_type api
              set rpc-permit read
              set profileid Restricted_User    (oder ein eigenes Profil mit Lesezugriff auf Device Manager)
              set adom "all_adoms"             (oder die gewünschten ADOMs)
          next
      end
      execute api-user generate-key loginventory_api

  Alternativ: ein normaler Administrator (Benutzername/Passwort) mit "JSON API Access" = Read.

  Für das Auslesen von FortiSwitches und FortiAPs leitet der FortiManager Anfragen an die FortiGates weiter
  (/sys/proxy/json). Falls dies mit reinen Leserechten abgelehnt wird (Fehlercode -11), muss "rpc-permit"
  auf "read-write" gesetzt werden. Das Skript selbst ändert keine Daten, weder im FortiManager noch auf den FortiGates.

.PARAMETER
Diese Parameter können Sie im RemoteScanner in der Skriptbasierten Inventarisierung unter Parameter hinterlegen:

Pflicht:
- fmgHost               Adresse des FortiManagers, z.B. "fortimanager.firma.local" oder "https://10.0.0.5:8443"
- apiKey                API-Schlüssel des REST-API-Administrators (empfohlen; Passwort-Checkbox aktivieren)
  oder
- username / password   Benutzername und Passwort eines Administrators mit JSON-API-Zugriff

Optional:
- adoms                 Nur diese ADOMs auslesen, mehrere durch Komma oder | getrennt (Standard: alle)
- nameFilter            Nur FortiGates, deren Name auf dieses Muster passt, z.B. "FGT-MUC*" (Standard: alle)
- includeSwitches       FortiSwitches erfassen: true/false (Standard: true)
- includeAccessPoints   FortiAPs erfassen: true/false (Standard: true)
- includeSwitchPorts    Ports und VLANs der FortiSwitches als Netzwerkadapter bzw. VLANs erfassen: true/false (Standard: true)
- includeMacTable       MAC-Adresstabelle der FortiSwitches erfassen (Grundlage der Topologie-Ansicht): true/false (Standard: true)
                        Ports, VLANs und MAC-Tabelle werden nur bei componentSource "proxy" gelesen und benötigen nur Lesezugriff.
- componentSource      Quelle für FortiSwitches/FortiAPs:
                          "proxy" (Standard) = Live-Abfrage der FortiGates über den FortiManager
                          "fmg"              = Statusdaten aus der FortiManager-Datenbank (_controller/status)
- siteMetaField         Name eines FortiManager Meta-Felds der FortiGate, das den Standort enthält.
                        Der Wert wird als Standort (DeviceInfo.Location) und Custom.Site an FortiGate, Switches und APs geschrieben.
- exportMetaFields      Alle Meta-Felder der FortiGate als Eigene Eigenschaften "Custom.FMG_<Feld>" übernehmen: true/false (Standard: false)
- skipCertificateCheck  Zertifikatsprüfung des FortiManagers abschalten (selbstsignierte Zertifikate): true/false (Standard: false)
- useWebProxy           Den in LOGINventory konfigurierten Web-Proxy auch für den FortiManager verwenden: true/false (Standard: false)
- proxyTimeout          Zeitlimit in Sekunden für die Weiterleitung an eine FortiGate (Standard: 60)
- useSerialAsCustomId   Seriennummer zusätzlich als CustomId schreiben, Wiedererkennung dann ausschließlich über die Seriennummer:
                        true/false (Standard: false). Sinnvoll, wenn mehrere Geräte denselben Namen tragen (z.B. Access Points
                        an verschiedenen Standorten). Achtung: Bereits ohne CustomId erfasste Assets (z.B. per SNMP) werden
                        dann nicht mehr zugeordnet, es entstehen neue Assets. Die Einstellung daher vor dem ersten Import festlegen.
- rawDumpDir            Verzeichnis, in das die Rohantworten der API als JSON geschrieben werden (zur Analyse beim Einrichten)
- DebugFile             Pfad zu einer Text-Datei für Debug-Ausgaben

Beim Eintragen der Werte im Remote Scanner können Anführungszeichen weggelassen werden.
#>

# Default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)
. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "include\WebRequest.ps1")

$ctx = New-CommonContext -Parameters $parameter -StartLabel 'FortiManager'
# End of default header ----------------------------------------------------------------------


# ------------ CONFIGURATION -----------------

$p = $ctx.UserParameters

$fmgHost             = [string]$p['fmgHost']
$apiKey              = [string]$p['apiKey']
$username            = [string]$p['username']
$password            = [string]$p['password']
$adomFilter          = @(([string]$p['adoms']) -split '[,|]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$nameFilter          = [string]$p['nameFilter']
$includeSwitches     = if (HasValue $p['includeSwitches'])     { ConvertTo-Bool $p['includeSwitches'] }     else { $true }
$includeAccessPoints = if (HasValue $p['includeAccessPoints']) { ConvertTo-Bool $p['includeAccessPoints'] } else { $true }
$componentSource     = if (HasValue $p['componentSource'])     { ([string]$p['componentSource']).Trim().ToLowerInvariant() } else { 'proxy' }
$siteMetaField       = [string]$p['siteMetaField']
$exportMetaFields    = ConvertTo-Bool $p['exportMetaFields']
$skipCertCheck       = ConvertTo-Bool $p['skipCertificateCheck']
$useWebProxy         = ConvertTo-Bool $p['useWebProxy']
$proxyTimeout        = if (HasValue $p['proxyTimeout']) { [int]$p['proxyTimeout'] } else { 60 }
$rawDumpDir          = [string]$p['rawDumpDir']
$useSerialAsCustomId = ConvertTo-Bool $p['useSerialAsCustomId']
$includeSwitchPorts  = if (HasValue $p['includeSwitchPorts']) { ConvertTo-Bool $p['includeSwitchPorts'] } else { $true }
$includeMacTable     = if (HasValue $p['includeMacTable'])    { ConvertTo-Bool $p['includeMacTable'] }    else { $true }

# The Job Monitor reads one event per line: keep every message on a single line
# (FortiManager error texts end with a line break).
$script:NotifyBase = ${function:Notify}
function Notify {
    param([string]$itemName, [string]$name, [string]$message, [string]$category, [string]$state, [string]$info, [int]$resultCode, [string]$itemResult)
    $PSBoundParameters['message'] = ([string]$message -replace '\s*[\r\n]+\s*', ' ').Trim()
    & $script:NotifyBase @PSBoundParameters
}

if (-not (HasValue $fmgHost)) {
    Notify -name "Error" -itemName "Configuration" -message "Parameter fmgHost is missing." -category "Error" -state "Faulty" -itemResult "Error"
    throw "Parameter fmgHost is missing."
}
if (-not (HasValue $apiKey) -and -not ((HasValue $username) -and (HasValue $password))) {
    Notify -name "Error" -itemName "Configuration" -message "Either apiKey or username and password must be set." -category "Error" -state "Faulty" -itemResult "Error"
    throw "Either apiKey or username and password must be set."
}
if ($componentSource -notin @('proxy', 'fmg')) {
    throw "Invalid componentSource '$componentSource' (allowed: proxy, fmg)."
}

$fmgBase = $fmgHost.Trim().TrimEnd('/')
if ($fmgBase -notmatch '^\w+://') { $fmgBase = "https://$fmgBase" }
$rpcUrl = "$fmgBase/jsonrpc"

# The LOGINventory web proxy is meant for internet access; a FortiManager is usually internal.
$rpcProxy = if ($useWebProxy) { $ctx.ProxyConfig } else { $null }

if ($skipCertCheck) {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        # Invoke-LoginWebRequest calls Invoke-RestMethod; default parameter values reach it through dynamic scoping.
        $PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
    }
    else {
        if (-not ('LoginTrustAllCertsPolicy' -as [type])) {
            Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class LoginTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
        }
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object LoginTrustAllCertsPolicy
    }
}
if ($PSVersionTable.PSVersion.Major -lt 7) {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}

if (HasValue $rawDumpDir) {
    if (-not (Test-Path $rawDumpDir)) { New-Item -Path $rawDumpDir -ItemType Directory -Force | Out-Null }
}


# ------------ HELPERS -----------------

$script:rpcId = 0
$script:fmgSession = $null

function Save-RawDump {
    # Writes an API response to rawDumpDir (only when the parameter is set).
    param([string]$Name, $Data)
    if (-not (HasValue $rawDumpDir)) { return }
    $file = Join-Path $rawDumpDir ((New-SafeFileName -Name $Name) + '.json')
    ConvertTo-Json -InputObject $Data -Depth 30 | Out-File -FilePath $file -Encoding UTF8
}

function Invoke-FmgRpc {
    <#
        Sends one JSON-RPC request to the FortiManager and returns result[0].
        Throws when the HTTP call fails or result[0].status.code is not 0.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][hashtable]$Params
    )

    $script:rpcId++
    $request = [ordered]@{
        id      = $script:rpcId
        method  = $Method
        params  = @($Params)
        verbose = 1
    }
    if ($script:fmgSession) { $request.session = $script:fmgSession }

    $headers = @{ 'Accept' = 'application/json' }
    if (HasValue $apiKey) { $headers['Authorization'] = "Bearer $apiKey" }

    $body = ConvertTo-Json -InputObject $request -Depth 20 -Compress
    $resp = Invoke-LoginWebRequest -Method POST -Uri $rpcUrl -Headers $headers -Body $body -ProxyConfig $rpcProxy -DebugFile $ctx.DebugFile

    if (-not $resp.IsSuccess) {
        throw "FortiManager request '$($Params.url)' failed: HTTP $($resp.StatusCode) $($resp.StatusDescription)"
    }

    $json = $resp.Body | ConvertFrom-Json
    $result = @($json.result)[0]
    if ($null -eq $result) {
        throw "FortiManager request '$($Params.url)' returned no result."
    }
    if ($null -ne $result.status -and [int]$result.status.code -ne 0) {
        throw "FortiManager request '$($Params.url)' failed: code $($result.status.code) - $($result.status.message)"
    }

    # The login call returns the session token next to "result".
    if ($json.PSObject.Properties['session'] -and $json.session) {
        $result | Add-Member -NotePropertyName '_session' -NotePropertyValue $json.session -Force
    }
    return $result
}

function Get-Prop {
    # Reads a property that may contain dashes or spaces; returns $null when missing.
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($n in $Names) {
        $prop = $Object.PSObject.Properties[$n]
        if (-not $prop -or $null -eq $prop.Value) { continue }
        $v = $prop.Value
        # Objects and lists are returned as they are (callers wrap lists in @()); text only when it is not blank.
        if ($v -is [string]) { if (-not [string]::IsNullOrWhiteSpace($v)) { return $v } else { continue } }
        return $v
    }
    return $null
}

function Format-Mac {
    param([string]$Mac)
    if (-not (HasValue $Mac)) { return $null }
    $hex = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($hex.Length -ne 12 -or $hex -eq '000000000000') { return $null }
    return (($hex -split '(..)' | Where-Object { $_ }) -join ':')
}

function ConvertTo-StatusText {
    # FortiManager returns symbolic values with verbose=1, numeric ones otherwise.
    param($Value, [hashtable]$Map)
    if ($null -eq $Value) { return $null }
    $key = [string]$Value
    if ($Map.ContainsKey($key)) { return $Map[$key] }
    return $key
}

function Get-FortiOsVersion {
    # Builds "7.2.8" from os_ver / mr / patch (os_ver is "7.0" with verbose=1, 7 without).
    param($Device)
    $major = $null
    if (HasValue $Device.os_ver) { $major = ([string]$Device.os_ver -split '\.')[0] }
    if (-not ($major -match '^\d+$') -and (HasValue $Device.version)) { $major = [string][math]::Floor([int]$Device.version / 100) }
    if (-not ($major -match '^\d+$')) { return $null }

    $ver = $major
    if ($null -ne $Device.mr -and [string]$Device.mr -match '^\d+$') { $ver += ".$($Device.mr)" }
    if ($null -ne $Device.patch -and [string]$Device.patch -match '^\d+$') { $ver += ".$($Device.patch)" }
    return $ver
}

function Split-ComponentOsVersion {
    <#
        Splits FortiSwitch/FortiAP version strings such as
          "S124EF-v6.4.6-build470,210211 (GA)"  or  "FP221E-v6.4-build0460"
        into model code, version and build.
    #>
    param([string]$OsVersion)
    $r = [pscustomobject]@{ Code = $null; Version = $null; Build = $null }
    if (-not (HasValue $OsVersion)) { return $r }
    $m = [regex]::Match($OsVersion, '^(?<code>[A-Za-z0-9]+)-v(?<ver>\d+(?:\.\d+)*)(?:-build(?<build>\d+))?')
    if ($m.Success) {
        $r.Code    = $m.Groups['code'].Value
        $r.Version = $m.Groups['ver'].Value
        if ($m.Groups['build'].Success) { $r.Build = $m.Groups['build'].Value }
    }
    return $r
}

function Get-ComponentProductName {
    # Derives a readable model name from the model code when FortiManager does not provide the platform.
    param([string]$Code, [string]$Kind)
    if (-not (HasValue $Code)) { return $null }
    if ($Kind -eq 'Switch') {
        if ($Code -match '^S(?<m>.+)$') { return "FortiSwitch-$($Matches['m'])" }
        return "FortiSwitch $Code"
    }
    if ($Code -match '^FP(?<m>.+)$') { return "FortiAP-$($Matches['m'])" }
    if ($Code -match '^P(?<m>U.+)$') { return "FortiAP-$($Matches['m'])" }
    return "FortiAP $Code"
}

function ConvertTo-CustomName {
    # Custom property names: letters, digits and underscore only.
    param([string]$Name)
    $n = ($Name -replace '[^A-Za-z0-9_]', '_') -replace '_{2,}', '_'
    return $n.Trim('_')
}

function Write-DeviceEntity {
    <#
        Writes one Device into the inventory.
        common.ps1 groups "Prefix.Property" entries only when they are consecutive, so the
        entries are emitted grouped by prefix (top-level properties first).
    #>
    param(
        [System.Collections.Specialized.OrderedDictionary]$Props,
        # Repeated groups (ports, VLANs, MAC table) as @(name, value) pairs. Every row must start
        # with its group's key property, common.ps1 opens a new element when that key repeats.
        [System.Collections.IEnumerable]$Rows
    )

    NewEntity -name "Device"
    # Reactivate archived assets
    AddPropertyValue -name "Archived" -value ""

    $groups = [ordered]@{ '' = New-Object System.Collections.ArrayList }
    foreach ($key in $Props.Keys) {
        $value = $Props[$key]
        if (-not (HasValue $value)) { continue }
        $prefix = if ($key -match '^([^.{]+)\.') { $Matches[1] } else { '' }
        if (-not $groups.Contains($prefix)) { $groups[$prefix] = New-Object System.Collections.ArrayList }
        [void]$groups[$prefix].Add(@($key, [string]$value))
    }
    foreach ($prefix in $groups.Keys) {
        foreach ($entry in $groups[$prefix]) {
            AddPropertyValue -name $entry[0] -value $entry[1]
        }
    }
    if ($Rows) {
        foreach ($entry in $Rows) {
            if (HasValue $entry[1]) { AddPropertyValue -name $entry[0] -value ([string]$entry[1]) }
        }
    }
}

function Get-PortIndexMap {
    <#
        Interface index per port name of one switch:
          physical ports "portN" -> N
          trunks and other ports (e.g. "Aggr1") -> 1001, 1002, ... (sorted by name, so the numbers stay stable)
    #>
    param([System.Collections.IEnumerable]$PortNames)
    $map = @{}
    $others = New-Object System.Collections.ArrayList
    foreach ($pn in $PortNames) {
        if ([string]$pn -match '^port(\d+)$') { $map[[string]$pn] = [int]$Matches[1] }
        elseif ($pn -and -not $others.Contains([string]$pn)) { [void]$others.Add([string]$pn) }
    }
    $next = 1000
    foreach ($pn in ($others | Sort-Object)) { $next++; $map[$pn] = $next }
    return $map
}

function Get-SwitchDetailRows {
    <#
        Builds the repeated groups of one FortiSwitch in the format of the SNMP scanner:
          NetworkAdapter.*      one per port (InterfaceIndex = port number, trunks from 1001, Speed in Mbit/s)
          Vlan.*                one per VLAN, port lists as "1;2;5"
          MacAddressTableRaw.*  one per learned MAC address
        $Status  : entry of /monitor/switch-controller/managed-switch/status (ports, link state, speed)
        $Config  : entry of /cmdb/switch-controller/managed-switch (native/allowed/untagged VLANs, descriptions)
        $VlanIds : hashtable VLAN interface name -> VLAN ID
        $Macs    : normalized MAC entries of this switch (Mac, Port, Vlan)
    #>
    param($Status, $Config, [hashtable]$VlanIds, $Macs, [bool]$WithPorts)

    $rows = New-Object System.Collections.ArrayList
    $configPorts = @{}
    if ($Config) { foreach ($cp in @($Config.ports)) { if ($cp) { $configPorts[[string](Get-Prop $cp @('port-name', 'name'))] = $cp } } }

    $statusPorts = @($Status.ports | Where-Object { $_ })
    $portNames = New-Object System.Collections.ArrayList
    foreach ($sp in $statusPorts) { [void]$portNames.Add([string]$sp.interface) }
    foreach ($k in $configPorts.Keys) { if (-not $portNames.Contains($k)) { [void]$portNames.Add($k) } }
    $portIndex = Get-PortIndexMap -PortNames $portNames

    if ($WithPorts) {
        $vlanPorts = [ordered]@{}   # vlan name -> @{ Egress = list; Untagged = list }
        foreach ($pn in ($portNames | Sort-Object { $portIndex[$_] })) {
            $num = $portIndex[$pn]
            if ($null -eq $num) { continue }
            $sp = $statusPorts | Where-Object { $_.interface -eq $pn } | Select-Object -First 1
            $cp = $configPorts[$pn]

            $speed = Get-Prop $sp @('speed')
            if ($null -ne $speed -and [int]$speed -le 0) { $speed = $null }
            $alias = Get-Prop $cp @('description')
            $isTrunk = ((Get-Prop $cp @('type')) -eq 'trunk') -or ($pn -notmatch '^port\d+$')
            if ($isTrunk -and -not $alias) {
                $members = @(@(Get-Prop $cp @('members')) | ForEach-Object { Get-Prop $_ @('member-name') } | Where-Object { $_ })
                if ($members.Count -gt 0) { $alias = "Trunk: " + ($members -join ', ') }
            }
            [void]$rows.Add(@('NetworkAdapter.InterfaceIndex', $num))
            [void]$rows.Add(@('NetworkAdapter.Name', $pn))
            if ($isTrunk) {
                [void]$rows.Add(@('NetworkAdapter.InterfaceType', 161))
                [void]$rows.Add(@('NetworkAdapter.InterfaceTypeName', 'ieee8023adLag'))
            }
            else {
                [void]$rows.Add(@('NetworkAdapter.InterfaceType', 6))
                [void]$rows.Add(@('NetworkAdapter.InterfaceTypeName', 'ethernetCsmacd'))
            }
            [void]$rows.Add(@('NetworkAdapter.InterfaceState', (Get-Prop $sp @('status'))))
            [void]$rows.Add(@('NetworkAdapter.InterfaceAlias', $alias))
            [void]$rows.Add(@('NetworkAdapter.Speed', $speed))

            # VLAN membership: native VLAN and "untagged-vlans" are untagged, "allowed-vlans" are tagged.
            $native = Get-Prop $cp @('vlan')
            if (-not $native) { $native = Get-Prop $sp @('vlan') }
            $untagged = @(@(Get-Prop $cp @('untagged-vlans')) | ForEach-Object { Get-Prop $_ @('vlan-name') } | Where-Object { $_ })
            $allowed  = @(@(Get-Prop $cp @('allowed-vlans'))  | ForEach-Object { Get-Prop $_ @('vlan-name') } | Where-Object { $_ })
            if ((Get-Prop $cp @('allowed-vlans-all')) -eq 'enable') { $allowed += @($VlanIds.Keys) }
            foreach ($v in @(@($native) + $untagged + $allowed | Where-Object { $_ } | Select-Object -Unique)) {
                if (-not $vlanPorts.Contains($v)) { $vlanPorts[$v] = @{ Egress = New-Object System.Collections.ArrayList; Untagged = New-Object System.Collections.ArrayList } }
                [void]$vlanPorts[$v].Egress.Add($num)
                if ($v -eq $native -or $untagged -contains $v) { [void]$vlanPorts[$v].Untagged.Add($num) }
            }
        }

        foreach ($v in $vlanPorts.Keys) {
            $id = $VlanIds[$v]
            if ($null -eq $id) { continue }   # Vlan.Id is numeric, VLANs without known ID are skipped
            [void]$rows.Add(@('Vlan.Id', $id))
            [void]$rows.Add(@('Vlan.Name', $v))
            [void]$rows.Add(@('Vlan.Status', 'permanent'))
            [void]$rows.Add(@('Vlan.EgressPorts', (@($vlanPorts[$v].Egress | Sort-Object -Unique) -join ';')))
            [void]$rows.Add(@('Vlan.UntaggedPorts', (@($vlanPorts[$v].Untagged | Sort-Object -Unique) -join ';')))
        }
    }

    # One entry per MAC and port (like the SNMP scanner). A MAC is often reported in several VLANs
    # on uplinks; an entry with a real VLAN wins over one without (VLAN 0).
    $entries = [ordered]@{}
    foreach ($m in @($Macs)) {
        if ($null -eq $m) { continue }
        $mac = Format-Mac -Mac $m.Mac
        if (-not $mac) { continue }
        $num = $portIndex[[string]$m.Port]
        if ($null -eq $num -and $m.PSObject.Properties['PortId'] -and [int]$m.PortId -gt 0) { $num = [int]$m.PortId }

        # VLAN may come as ID or as interface name
        $vlanId = $null; $vlanName = $null
        if ([string]$m.Vlan -match '^\d+$' -and [int]$m.Vlan -gt 0) {
            $vlanId = [string]$m.Vlan
            $vlanName = ($VlanIds.GetEnumerator() | Where-Object { [string]$_.Value -eq $vlanId } | Select-Object -First 1).Key
        }
        elseif ((HasValue $m.Vlan) -and [string]$m.Vlan -notmatch '^\d+$') {
            $vlanName = [string]$m.Vlan
            if ($null -ne $VlanIds[$vlanName]) { $vlanId = [string]$VlanIds[$vlanName] }
        }

        $key = "$mac|$($m.Port)"
        if ($entries.Contains($key) -and ($entries[$key].VlanId -or -not $vlanId)) { continue }
        $entries[$key] = [pscustomobject]@{ Mac = $mac; Num = $num; Port = $m.Port; VlanId = $vlanId; VlanName = $vlanName }
    }

    foreach ($e in $entries.Values) {
        [void]$rows.Add(@('MacAddressTableRaw.Mac', $e.Mac))
        [void]$rows.Add(@('MacAddressTableRaw.Port', $e.Num))
        [void]$rows.Add(@('MacAddressTableRaw.Status', 'learned'))
        [void]$rows.Add(@('MacAddressTableRaw.VLan', $e.VlanId))
        [void]$rows.Add(@('MacAddressTableRaw.VLanName', $e.VlanName))
        [void]$rows.Add(@('MacAddressTableRaw.InterfaceType', $e.Port))
        [void]$rows.Add(@('MacAddressTableRaw.InterfaceIndex', $e.Num))
    }
    return , $rows
}

$connStatusMap = @{ '0' = 'unknown'; '1' = 'up'; '2' = 'down' }
$confStatusMap = @{ '0' = 'unknown'; '1' = 'insync'; '2' = 'outofsync' }
$osTypeMap     = @{ 'fos' = 'FortiOS'; '0' = 'FortiOS'; 'foc' = 'FortiCarrier'; 'fpx' = 'FortiProxy'; 'ffw' = 'FortiFirewall' }
$roleMap       = @{ 'master' = 'Primary'; 'slave' = 'Secondary' }


# ------------ 1. LOGIN ------------------

$deviceCount = @{ Firewall = 0; Switch = 0; AccessPoint = 0 }
$seenSerials = @{}
$warnings    = 0

try {
    if (HasValue $apiKey) {
        Write-CommonDebug -Context $ctx -Message "Using API key authentication."
    }
    else {
        Write-CommonDebug -Context $ctx -Message "Logging in as $username ..."
        $login = Invoke-FmgRpc -Method exec -Params @{
            url  = '/sys/login/user'
            data = @(@{ user = $username; passwd = $password })
        }
        $script:fmgSession = $login._session
        if (-not $script:fmgSession) { throw "Login succeeded but no session was returned." }
    }

    $status = Invoke-FmgRpc -Method get -Params @{ url = '/sys/status' }
    $fmgVersion = Get-Prop $status.data @('Version', 'version')
    Notify -name "Connect" -itemName "FortiManager" -message "Connected to $fmgBase ($fmgVersion)" -category "Info" -state "Finished" -itemResult "Ok"
}
catch {
    Notify -name "Error" -itemName "FortiManager" -message "Connection/login failed: $($_.Exception.Message)" -category "Error" -state "Faulty" -itemResult "Error"
    throw
}

try {
    # ------------ 2. FORTIGATES ------------------

    $options = @('extra info')
    if ((HasValue $siteMetaField) -or $exportMetaFields) { $options += 'get meta' }

    $devices = New-Object System.Collections.ArrayList
    if ($adomFilter.Count -gt 0) {
        foreach ($adom in $adomFilter) {
            $r = Invoke-FmgRpc -Method get -Params @{ url = "/dvmdb/adom/$adom/device"; option = $options }
            Save-RawDump -Name "devices_$adom" -Data $r.data
            foreach ($d in @($r.data)) {
                if ($null -eq $d) { continue }
                $d | Add-Member -NotePropertyName '_adom' -NotePropertyValue $adom -Force
                [void]$devices.Add($d)
            }
        }
    }
    else {
        $r = Invoke-FmgRpc -Method get -Params @{ url = '/dvmdb/device'; option = $options }
        Save-RawDump -Name 'devices' -Data $r.data
        foreach ($d in @($r.data)) {
            if ($null -eq $d) { continue }
            $adom = Get-Prop (Get-Prop $d @('extra info')) @('adom')
            if (-not $adom) { $adom = 'root' }
            $d | Add-Member -NotePropertyName '_adom' -NotePropertyValue $adom -Force
            [void]$devices.Add($d)
        }
    }

    # Skip model devices (pre-provisioned placeholders) and unauthorized devices.
    $managed = @($devices | Where-Object {
        $flags = @($_.flags)
        $isModel = ($flags -contains 'is_model') -or (($_.flags -is [long] -or $_.flags -is [int]) -and (([long]$_.flags -band 262144) -ne 0))
        $isUnreg = ([string]$_.mgmt_mode -eq 'unreg')
        $nameOk  = (-not (HasValue $nameFilter)) -or ($_.name -like $nameFilter)
        (-not $isModel) -and (-not $isUnreg) -and $nameOk -and (HasValue $_.sn)
    })

    Notify -name "Information" -itemName "Evaluation" -itemResult "None" -message "Found $($managed.Count) managed FortiGate entries in FortiManager." -category "Info" -state "Detecting"

    $gateways = New-Object System.Collections.ArrayList   # used for the switch/AP lookups

    foreach ($dev in $managed) {
        $adom      = $dev._adom
        $fwVersion = Get-FortiOsVersion -Device $dev
        $fwBuild   = if (HasValue $dev.build) { [string]$dev.build } else { $null }
        $osName    = ConvertTo-StatusText -Value $dev.os_type -Map $osTypeMap
        if (-not $osName) { $osName = 'FortiOS' }
        $connText  = ConvertTo-StatusText -Value $dev.conn_status -Map $connStatusMap
        $confText  = ConvertTo-StatusText -Value $dev.conf_status -Map $confStatusMap
        $meta      = Get-Prop $dev @('meta fields')
        $site      = if (HasValue $siteMetaField) { Get-Prop $meta @($siteMetaField) } else { $null }

        # FortiManager cannot forward requests to a FortiGate without management tunnel ("No tunnel").
        $online = ($connText -ne 'down')
        [void]$gateways.Add([pscustomobject]@{ Name = $dev.name; Serial = $dev.sn; Adom = $adom; Site = $site; Online = $online })

        # HA cluster: FortiManager shows the cluster as one device, every member has its own serial number.
        $members = @(@($dev.ha_slave) | Where-Object { $_ -and (HasValue $_.sn) })
        if ($members.Count -lt 2) {
            $members = @([pscustomobject]@{ name = $dev.name; sn = $dev.sn; role = $null; status = $null; _standalone = $true })
        }
        $clusterName = if ($members.Count -ge 2) { if (HasValue $dev.ha_group_name) { $dev.ha_group_name } else { $dev.name } } else { $null }

        foreach ($m in $members) {
            $serial = ([string]$m.sn).Trim()
            if ($seenSerials.ContainsKey($serial)) { continue }
            $seenSerials[$serial] = $true

            $isStandalone = [bool]($m.PSObject.Properties['_standalone'])
            $role = ConvertTo-StatusText -Value $m.role -Map $roleMap
            $name = if (HasValue $m.name) { $m.name } else { $dev.name }

            $props = [ordered]@{}
            $props['Name']                                        = $name
            if ($useSerialAsCustomId) {
                $props['CustomId']                                = $serial
            }
            $props['SerialNumber']                                = $serial
            $props['DeviceInfo.ChassisType']                      = 'Firewall'
            $props['DeviceInfo.Description']                      = $dev.desc
            $props['DeviceInfo.Location']                         = $site
            $props['HardwareProduct.Manufacturer{Editable:true}'] = 'Fortinet'
            $props['HardwareProduct.Name']                        = $dev.platform_str
            $props['OperatingSystem.Name']                        = $osName
            $props['OperatingSystem.Version']                     = $fwVersion
            $props['LastInventory.Timestamp']                     = $ctx.TimeStamp2
            # The management IP belongs to the cluster; it is set on the primary (or standalone) unit only.
            if ($isStandalone -or $role -eq 'Primary') {
                $props['LastInventory.Ip']                        = $dev.ip
            }
            $props['Custom.Source']                               = 'FortiManager'
            $props['Custom.FortiManagerADOM']                     = $adom
            $props['Custom.FortiManagerDeviceName']               = $dev.name
            $props['Custom.FirmwareBuild']                        = $fwBuild
            $props['Custom.ConnectionStatus']                     = $connText
            $props['Custom.ConfigStatus']                         = $confText
            $props['Custom.Site']                                 = $site
            if (-not $isStandalone) {
                $props['Custom.HACluster']                        = $clusterName
                $props['Custom.HARole']                           = $role
                $props['Custom.HAMemberStatus']                   = ConvertTo-StatusText -Value $m.status -Map @{ '0' = 'down'; '1' = 'up'; '2' = 'down' }
                $props['Custom.HAPartnerSerials']                 = (@($members | Where-Object { $_.sn -ne $serial } | ForEach-Object { $_.sn }) -join ', ')
            }
            if ($exportMetaFields -and $meta) {
                foreach ($mp in $meta.PSObject.Properties) {
                    $cn = ConvertTo-CustomName -Name $mp.Name
                    if ($cn) { $props["Custom.FMG_$cn"] = $mp.Value }
                }
            }

            Write-DeviceEntity -Props $props
            $deviceCount.Firewall++
            Notify -name $name -itemName "FortiGate" -message "$name ($serial)" -category "Info" -state "Finished" -itemResult "Ok"
        }
    }


    # ------------ 3. FORTISWITCHES AND FORTIAPS ------------------

    function Add-Component {
        <#
            Writes one FortiSwitch or FortiAP. $Rec is a normalized record:
            Kind, Serial, Name, OsVersion, Ip, Mac, Status, State, Platform, Location, Profile, Interface, Gateway
        #>
        param($Rec)

        $serial = ([string]$Rec.Serial).Trim()
        if (-not (HasValue $serial)) { return }
        if ($seenSerials.ContainsKey($serial)) { return }
        $seenSerials[$serial] = $true

        $ver  = Split-ComponentOsVersion -OsVersion $Rec.OsVersion
        $kind = $Rec.Kind
        $gw   = $Rec.Gateway
        $name = if (HasValue $Rec.Name) { $Rec.Name } else { $serial }

        # Without a version string the model code is taken from the serial number (first 6 characters, e.g. "FP221E", "S124EF").
        if (-not (HasValue $ver.Code) -and $serial.Length -ge 6) { $ver.Code = $serial.Substring(0, 6).ToUpperInvariant() }

        $product = $Rec.Platform
        if (-not (HasValue $product)) { $product = Get-ComponentProductName -Code $ver.Code -Kind $kind }

        $location = if (HasValue $Rec.Location) { $Rec.Location } else { $gw.Site }

        $props = [ordered]@{}
        $props['Name']                                        = $name
        if ($useSerialAsCustomId) {
            $props['CustomId']                                = $serial
        }
        $props['SerialNumber']                                = $serial
        $props['DeviceInfo.ChassisType']                      = if ($kind -eq 'Switch') { 'Switch' } else { 'Access Point' }
        $props['DeviceInfo.Location']                         = $location
        $props['HardwareProduct.Manufacturer{Editable:true}'] = 'Fortinet'
        $props['HardwareProduct.Name']                        = $product
        $props['OperatingSystem.Name']                        = if ($kind -eq 'Switch') { 'FortiSwitchOS' } else { 'FortiAP OS' }
        $props['OperatingSystem.Version']                     = $ver.Version
        $props['LastInventory.Timestamp']                     = $ctx.TimeStamp2
        $props['LastInventory.Ip']                            = $Rec.Ip
        $props['LastInventory.Mac']                           = Format-Mac -Mac $Rec.Mac
        $props['Custom.Source']                               = 'FortiManager'
        $props['Custom.FortiManagerADOM']                     = $gw.Adom
        $props['Custom.FortiGate']                            = $gw.Name
        $props['Custom.FortiGateSerial']                      = $gw.Serial
        $props['Custom.FirmwareBuild']                        = $ver.Build
        $props['Custom.FirmwareString']                       = $Rec.OsVersion
        $props['Custom.ModelCode']                            = $ver.Code
        $props['Custom.ConnectionStatus']                     = $Rec.Status
        $props['Custom.AuthorizationState']                   = $Rec.State
        $props['Custom.Site']                                 = $gw.Site
        if ($kind -eq 'Switch') {
            $props['Custom.FortiLinkInterface']               = $Rec.Interface
        }
        else {
            $props['Custom.APProfile']                        = $Rec.Profile
            $props['Custom.ConnectingInterface']              = $Rec.Interface
        }

        $rows = if ($Rec.PSObject.Properties['Rows']) { $Rec.Rows } else { $null }
        Write-DeviceEntity -Props $props -Rows $rows
        if ($kind -eq 'Switch') { $script:deviceCount.Switch++ } else { $script:deviceCount.AccessPoint++ }
        $itemName = if ($kind -eq 'Switch') { 'FortiSwitch' } else { 'FortiAP' }
        Notify -name $name -itemName $itemName -message "$name ($serial) via $($gw.Name)" -category "Info" -state "Finished" -itemResult "Ok"
    }

    function Invoke-FgtMonitor {
        <#
            Runs a FortiOS REST monitor call on one FortiGate through FortiManager (/sys/proxy/json).
            Tries the given resources in order and returns the first one that answers.
        #>
        param([string]$Adom, [string]$Device, [string[]]$Resources)

        $lastError = $null
        foreach ($res in $Resources) {
            try {
                $r = Invoke-FmgRpc -Method exec -Params @{
                    url  = '/sys/proxy/json'
                    data = @{
                        target   = @("adom/$Adom/device/$Device")
                        action   = 'get'
                        resource = $res
                        timeout  = $proxyTimeout
                    }
                }
            }
            catch { $lastError = $_.Exception.Message; continue }

            Save-RawDump -Name "proxy_$($Device)_$($res -replace '\?.*$', '')" -Data $r.data

            $results = New-Object System.Collections.ArrayList
            $ok = $false
            foreach ($item in @($r.data)) {
                if ($null -eq $item) { continue }
                if ($item.status -and [int]$item.status.code -ne 0) { $lastError = "$($item.status.code) $($item.status.message)"; continue }
                foreach ($resp in @($item.response)) {
                    if ($null -eq $resp) { continue }
                    $http = Get-Prop $resp @('http_status')
                    if (($http -and [int]$http -ne 200) -or ([string](Get-Prop $resp @('status')) -eq 'error')) {
                        $lastError = "HTTP $http $(Get-Prop $resp @('error', 'message'))"
                        continue
                    }
                    $ok = $true
                    foreach ($x in @($resp.results)) { if ($null -ne $x) { [void]$results.Add($x) } }
                }
            }
            if ($ok) { return [pscustomobject]@{ Ok = $true; Results = $results; Resource = $res } }
        }
        return [pscustomobject]@{ Ok = $false; Results = @(); Error = $lastError }
    }

    if ($includeSwitches -or $includeAccessPoints) {

        # Switch platforms (e.g. "FortiSwitch-108F-FPOE") from FortiManager's switch table, FortiManager 7.4+.
        $switchPlatforms = @{}
        if ($includeSwitches) {
            foreach ($adom in @($gateways | ForEach-Object { $_.Adom } | Sort-Object -Unique)) {
                try {
                    $r = Invoke-FmgRpc -Method get -Params @{ url = "/pm/config/adom/$adom/obj/fsp/managed-switch"; 'scope member' = @(@{ name = 'All_FortiGate' }) }
                    Save-RawDump -Name "fsp_managed-switch_$adom" -Data $r.data
                    foreach ($s in @($r.data)) {
                        $platform = Get-Prop $s @('platform')
                        if (-not $platform) { continue }
                        foreach ($k in @((Get-Prop $s @('sn')), (Get-Prop $s @('switch-id')))) { if ($k) { $switchPlatforms[[string]$k] = $platform } }
                    }
                }
                catch {
                    Write-CommonDebug -Context $ctx -Message "Switch platform table not available in ADOM ${adom}: $($_.Exception.Message)"
                }
            }
        }

        if ($componentSource -eq 'proxy') {
            # Live data: ask every FortiGate (once per FortiManager device, i.e. once per HA cluster).
            $byDevice = @($gateways | Group-Object -Property Name)
            $i = 0
            foreach ($g in $byDevice) {
                $i++
                $gw = $g.Group[0]

                if (-not $gw.Online) {
                    Notify -name "Offline $($gw.Name)" -itemName "FortiGate" -itemResult "Excluded" -message "$($gw.Name) is not connected to FortiManager, its switches and access points were skipped." -category "Info" -state "Finished"
                    continue
                }

                Notify -name "Getting Data" -itemName "Getting Data" -itemResult "None" -message "[$i/$($byDevice.Count)] Querying switches and access points of $($gw.Name)" -category "Info" -state "Detecting"

                if ($includeSwitches) {
                    $res = Invoke-FgtMonitor -Adom $gw.Adom -Device $gw.Name -Resources @(
                        '/api/v2/monitor/switch-controller/managed-switch/status?vdom=*',
                        '/api/v2/monitor/switch-controller/managed-switch/status',
                        '/api/v2/monitor/switch-controller/managed-switch?vdom=*'
                    )
                    if ($res.Ok -and $res.Results.Count -gt 0) {

                        # Ports and VLANs: switch configuration and the VLAN IDs of the FortiLink VLAN interfaces
                        $switchConfigs = @{}
                        $vlanIds = @{}
                        if ($includeSwitchPorts) {
                            $cfg = Invoke-FgtMonitor -Adom $gw.Adom -Device $gw.Name -Resources @('/api/v2/cmdb/switch-controller/managed-switch')
                            if ($cfg.Ok) {
                                foreach ($c in $cfg.Results) {
                                    foreach ($k in @((Get-Prop $c @('switch-id')), (Get-Prop $c @('sn')))) { if ($k) { $switchConfigs[[string]$k] = $c } }
                                }
                            }
                            else {
                                $warnings++
                                Notify -name "Switch config $($gw.Name)" -itemName "FortiSwitch" -message "Could not read switch port configuration of $($gw.Name): $($cfg.Error)" -category "Warning" -state "Finished" -itemResult "Error"
                            }
                        }
                        if ($includeSwitchPorts -or $includeMacTable) {
                            $ifs = Invoke-FgtMonitor -Adom $gw.Adom -Device $gw.Name -Resources @('/api/v2/cmdb/system/interface?format=name|vlanid|interface|type')
                            if ($ifs.Ok) {
                                foreach ($if in $ifs.Results) {
                                    $vid = Get-Prop $if @('vlanid')
                                    if ($vid -and [int]$vid -gt 0) { $vlanIds[[string]$if.name] = [int]$vid }
                                }
                            }
                        }

                        # MAC address table: devices learned on the switch ports
                        $macsBySwitch = @{}
                        if ($includeMacTable) {
                            $det = Invoke-FgtMonitor -Adom $gw.Adom -Device $gw.Name -Resources @(
                                '/api/v2/monitor/switch-controller/detected-device?vdom=*',
                                '/api/v2/monitor/switch-controller/detected-device'
                            )
                            if ($det.Ok) {
                                foreach ($d in $det.Results) {
                                    $swKey = Get-Prop $d @('switch_id', 'switch-id', 'switch_serial', 'fsw_serial', 'switch', 'sn', 'serial')
                                    if (-not $swKey) { continue }
                                    if (-not $macsBySwitch.ContainsKey([string]$swKey)) { $macsBySwitch[[string]$swKey] = New-Object System.Collections.ArrayList }
                                    [void]$macsBySwitch[[string]$swKey].Add([pscustomobject]@{
                                        Mac  = Get-Prop $d @('mac', 'mac_address', 'mac-address')
                                        Port = Get-Prop $d @('port_name', 'port', 'port-name', 'interface')
                                        Vlan = Get-Prop $d @('vlan_id', 'vlan', 'vlan-id', 'vlanid', 'vlan_name')
                                        PortId = Get-Prop $d @('port_id')
                                    })
                                }
                            }
                            else {
                                $warnings++
                                Notify -name "MAC table $($gw.Name)" -itemName "FortiSwitch" -message "Could not read MAC address table of $($gw.Name): $($det.Error)" -category "Warning" -state "Finished" -itemResult "Error"
                            }
                        }

                        foreach ($s in $res.Results) {
                            $serial = Get-Prop $s @('serial', 'switch-id', 'switch_id', 'sn')
                            $swId   = Get-Prop $s @('switch-id', 'switch_id', 'name')
                            $rows = $null
                            if ($includeSwitchPorts -or $includeMacTable) {
                                $config = $switchConfigs[[string]$swId]
                                if (-not $config) { $config = $switchConfigs[[string]$serial] }
                                $macs = @()
                                foreach ($k in @($swId, $serial)) { if ($k -and $macsBySwitch.ContainsKey([string]$k)) { $macs += @($macsBySwitch[[string]$k]) } }
                                $rows = Get-SwitchDetailRows -Status $s -Config $config -VlanIds $vlanIds -Macs $macs -WithPorts $includeSwitchPorts
                            }
                            Add-Component ([pscustomobject]@{
                                Rows      = $rows
                                Kind      = 'Switch'
                                Serial    = $serial
                                Name      = Get-Prop $s @('name', 'switch-id', 'switch_id')
                                OsVersion = Get-Prop $s @('os_version')
                                Ip        = Get-Prop $s @('connecting_from')
                                Mac       = $null
                                Status    = Get-Prop $s @('status')
                                State     = Get-Prop $s @('state')
                                Platform  = $switchPlatforms[[string]$serial]
                                Location  = $null
                                Profile   = $null
                                Interface = Get-Prop $s @('fgt_peer_intf_name')
                                Gateway   = $gw
                            })
                        }
                    }
                    elseif (-not $res.Ok) {
                        $warnings++
                        Notify -name "Switches $($gw.Name)" -itemName "FortiSwitch" -message "Could not query switches of $($gw.Name): $($res.Error)" -category "Warning" -state "Finished" -itemResult "Error"
                    }
                }

                if ($includeAccessPoints) {
                    $res = Invoke-FgtMonitor -Adom $gw.Adom -Device $gw.Name -Resources @(
                        '/api/v2/monitor/wifi/managed_ap?vdom=*',
                        '/api/v2/monitor/wifi/managed_ap'
                    )
                    if ($res.Ok) {
                        foreach ($a in $res.Results) {
                            $ip = Get-Prop $a @('connecting_from', 'local_ipv4_addr')
                            if ($ip -eq '0.0.0.0') { $ip = $null }
                            Add-Component ([pscustomobject]@{
                                Kind      = 'AccessPoint'
                                Serial    = Get-Prop $a @('serial', 'wtp_id')
                                Name      = Get-Prop $a @('name', 'wtp_id')
                                OsVersion = Get-Prop $a @('os_version')
                                Ip        = $ip
                                Mac       = Get-Prop $a @('board_mac')
                                Status    = Get-Prop $a @('status', 'connection_state')
                                State     = Get-Prop $a @('state')
                                Platform  = $null
                                Location  = Get-Prop $a @('location')
                                Profile   = Get-Prop $a @('ap_profile')
                                Interface = Get-Prop $a @('connecting_interface')
                                Gateway   = $gw
                            })
                        }
                    }
                    else {
                        $warnings++
                        Notify -name "Access points $($gw.Name)" -itemName "FortiAP" -message "Could not query access points of $($gw.Name): $($res.Error)" -category "Warning" -state "Finished" -itemResult "Error"
                    }
                }
            }

            # Close the progress line, otherwise the Job Monitor keeps it in "Detecting" and its runtime keeps counting.
            $onlineCount = @($byDevice | Where-Object { $_.Group[0].Online }).Count
            Notify -name "Getting Data" -itemName "Getting Data" -itemResult "Ok" -message "Queried switches and access points of $onlineCount FortiGates ($($byDevice.Count - $onlineCount) not connected)." -category "Info" -state "Finished"
        }
        else {
            # FortiManager database: status of the controlled devices as last seen by FortiManager.
            $gwByName = @{}
            foreach ($gw in $gateways) { if (-not $gwByName.ContainsKey($gw.Name)) { $gwByName[$gw.Name] = $gw } }

            $kinds = @()
            if ($includeSwitches)     { $kinds += 'fsw' }
            if ($includeAccessPoints) { $kinds += 'fap' }

            foreach ($adom in @($gateways | ForEach-Object { $_.Adom } | Sort-Object -Unique)) {
                foreach ($kind in $kinds) {
                    try {
                        $r = Invoke-FmgRpc -Method get -Params @{ url = "/pm/config/adom/$adom/_controller/status/$kind"; 'scope member' = @(@{ name = 'All_FortiGate' }) }
                    }
                    catch {
                        $warnings++
                        Notify -name "Status $kind $adom" -itemName $kind -message "Could not read controller status ($kind) in ADOM ${adom}: $($_.Exception.Message)" -category "Warning" -state "Finished" -itemResult "Error"
                        continue
                    }
                    Save-RawDump -Name "controller_status_$($kind)_$adom" -Data $r.data

                    foreach ($item in @($r.data)) {
                        if ($null -eq $item) { continue }
                        $gw = $gwByName[[string]$item.dev]
                        if (-not $gw) { continue }   # FortiGate filtered out or unknown
                        # "data" is a JSON string with the details of the switch or access point.
                        $d = $null
                        if ($item.data -is [string]) { try { $d = $item.data | ConvertFrom-Json } catch { $d = $null } } else { $d = $item.data }

                        $serial = Get-Prop $item @('sn')
                        if (-not $serial) { $serial = Get-Prop $d @('serial', 'wtp_id', 'switch-id', 'switch_id', 'sn') }

                        if ($kind -eq 'fsw') {
                            Add-Component ([pscustomobject]@{
                                Kind      = 'Switch'
                                Serial    = $serial
                                Name      = Get-Prop $d @('name', 'switch-id', 'switch_id')
                                OsVersion = Get-Prop $d @('os_version', 'version')
                                Ip        = Get-Prop $d @('connecting_from', 'ip')
                                Mac       = $null
                                Status    = Get-Prop $d @('status', 'connection_state')
                                State     = Get-Prop $d @('state')
                                Platform  = $switchPlatforms[[string]$serial]
                                Location  = $null
                                Profile   = $null
                                Interface = Get-Prop $d @('fgt_peer_intf_name')
                                Gateway   = $gw
                            })
                        }
                        else {
                            $ip = Get-Prop $d @('connecting_from', 'local_ip', 'local_ipv4_addr')
                            if ($ip -eq '0.0.0.0') { $ip = $null }
                            Add-Component ([pscustomobject]@{
                                Kind      = 'AccessPoint'
                                Serial    = $serial
                                Name      = Get-Prop $d @('name', 'wtp_id')
                                OsVersion = Get-Prop $d @('os_version')
                                Ip        = $ip
                                Mac       = Get-Prop $d @('board_mac')
                                Status    = Get-Prop $d @('connection_state', 'status')
                                State     = Get-Prop $d @('admin', 'state')
                                Platform  = $null
                                Location  = Get-Prop $d @('location')
                                Profile   = Get-Prop $d @('wtp_profile', 'ap_profile')
                                Interface = $null
                                Gateway   = $gw
                            })
                        }
                    }
                }
            }
        }
    }


    # ------------ 4. WRITE .inv FILE ------------------

    $total = $deviceCount.Firewall + $deviceCount.Switch + $deviceCount.AccessPoint
    $summary = "FortiGates: $($deviceCount.Firewall), FortiSwitches: $($deviceCount.Switch), FortiAPs: $($deviceCount.AccessPoint)"

    if ($total -gt 0) {
        $filePath = Join-Path $ctx.DataDir "$($ctx.TimeStamp)@FortiManager.inv"
        WriteInv -filePath $filePath -version $ctx.Version
        Notify -name "Writing Data" -itemName "Inventory" -itemResult "Ok" -message "FortiManager" -category "Info" -state "Finished"
    }

    $resultCategory = if ($warnings -gt 0) { 'Warning' } else { 'Info' }
    if ($warnings -gt 0) { $summary += " ($warnings query warnings, see above)" }
    Notify -name "Information" -itemName "Evaluation" -itemResult "Ok" -message $summary -category $resultCategory -state "Finished"
}
catch {
    Notify -name "ERROR" -itemName "Error" -message "$($_.Exception.Message) - line $($_.InvocationInfo.ScriptLineNumber)" -category "Error" -state "Faulty" -itemResult "Error"
    throw
}
finally {
    if ($script:fmgSession) {
        try { [void](Invoke-FmgRpc -Method exec -Params @{ url = '/sys/logout' }) } catch { }
        $script:fmgSession = $null
    }
}
