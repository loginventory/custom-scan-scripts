# Skriptbasierte Inventarisierung mit LOGINventory

> **Sie suchen den Ordner `include` oder ein bestimmtes Skript?** Seit November 2026 liegen alle freigegebenen Skripte und der Ordner `include` im Ordner [`catalog/`](catalog/) und nicht mehr im Hauptverzeichnis des Repos. Die Dateien sind dieselben, nur ihr Ort im Zip hat sich geändert. Der Inhalt von `catalog/` entspricht genau dem Aufbau des `Agents`-Ordners, siehe [Voraussetzungen](#vorraussetzungen). Ältere Handbuchstände beschreiben noch die alte Ablage.

Mit der skriptbasierten Inventarisierung ist es möglich, über den LOGINventory Remote Scanner eigene Skripte zur Erzeugung dynamischer Inventardatensätze auszuführen. Hierfür steht der Definitionstyp "Skriptbasierte Inventarisierung" zur Verfügung.
In diesem Definitionstyp können Parameter hinterlegt werden, welche an die Skripte übergeben werden und somit dort zur Verfügung stehen. Ziel ist es, eine .inv Datei im Datenverzeichnis zu erzeugen, welche mittels LOGINsert.exe in die LOGINventory Datenbank eingetragen wird.
Diese .inv Dateien sind XML Dateien, welche ein LOGINventory konformes Schema aufweisen müssen. Um die Handhabung zu vereinfachen, kann in den Skripten eine vereinfachte Syntax -name "Tabelle.Eigenschaft" -value "Wert" verwendet werden (siehe [Grundlegende Verwendung](#grundlegende-verwendung)).

In [diesem Beispiel](step-by-step-example.md) zeigen wir die **exemplarische Verwendung** der skriptbasierten Inventarisierung zum **Anlegen von Assets in LOGINventory durch die Inventarisierung des Azure-Active-Directory**.

Bei Pfadangaben gilt: "INSTALLDIR" entspricht Ihrem LOGINventory Installationsverzeichnis. Sollte ein hier erwähntes Verzeichnis lokal noch nicht existieren, erstellen Sie dieses. Diese Struktur wird nicht durch das LOGINventory Setup angelegt.

## Übersicht über verfügbare Skripte

Die folgenden Skripte sind freigegeben und liegen in [`catalog/`](catalog/). Die Tabelle wird mit `tools/Update-Readme.ps1` aus den [Manifesten](#skript-manifest) der Skripte erzeugt.

<!-- catalog:begin -->
<!-- Erzeugt von tools/Update-Readme.ps1 aus den Manifesten in catalog/, nicht von Hand ändern -->
Skript | Beschreibung | Was wird in LOGINventory erzeugt? | Stufe | Version
-------|--------------|-----------------------------------|-------|--------
[Adobe-Cloud-Subscriptions.ps1](catalog/Adobe-Cloud-Subscriptions.ps1) | **Adobe Cloud-Abonnements**: Liest Benutzer und ihre zugewiesenen Lizenzen über die Adobe User Management API (UMAPI) und legt sie als Cloud-Subscriptions und Lizenzen an. | Cloud-Subscriptions, Lizenzen | LOGIN | 1.0.0
[AppTec360-MobileDevices.ps1](catalog/AppTec360-MobileDevices.ps1) | **AppTec360 EMM: mobile Geräte**: Liest Smartphones und Tablets über die REST-API von AppTec360 EMM und legt sie als Assets an. | Assets | LOGIN | 1.0.0
[AzureAd-Devices-Compliant.ps1](catalog/AzureAd-Devices-Compliant.ps1) | **Microsoft Entra ID Geräte mit Compliance-Status**: Liest Geräte aus Microsoft Entra ID (Azure AD) über Microsoft Graph, legt sie als Assets an und speichert den Compliance-Status als Eigene Eigenschaft. | Assets, Eigene Eigenschaften | LOGIN | 2.0.0
[baramundi-MobileDevices.ps1](catalog/baramundi-MobileDevices.ps1) | **baramundi: mobile Geräte**: Liest Smartphones und Tablets über die bConnect-API von baramundi und legt sie als Assets an. | Assets | LOGIN | 1.0.0
[csv-user-import.ps1](catalog/csv-user-import.ps1) | **Benutzer aus CSV-Datei**: Liest Benutzer aus einer CSV-Datei (Trennzeichen Semikolon, Spaltennamen wie in der Tabelle UserAccount) und legt sie als Benutzerkonten an. Pflichtspalten: Name und ObjectSID. | Benutzerkonten | LOGIN | 1.0.0
[CyberInsight.ps1](catalog/CyberInsight.ps1) | **Cyber Insight Schwachstellenanalyse**: Überträgt Inventardaten an Cyber Insight (Action=Post) und holt die erkannten Schwachstellen je Software-Paket ab (Action=Get). API-Key und Firmenname werden in LOGINventory.config hinterlegt, siehe Handbuch. Benötigt zusätzlich den Ordner [CyberInsight/](catalog/CyberInsight/). Läuft mit der LOGINventory PowerShell (`engine` = `psc.exe`). | Schwachstellen | LOGIN | 1.0.0
[IntuneDevices.ps1](catalog/IntuneDevices.ps1) | **Microsoft Intune Geräte**: Liest in Intune verwaltete Geräte über Microsoft Graph und legt sie als Assets an, wahlweise nur mobile Geräte. | Assets | LOGIN | 3.0.0
[jetbrains.ps1](catalog/jetbrains.ps1) | **JetBrains Lizenzen**: Liest Produktlizenzen über die JetBrains Account API und legt sie als Cloud-Subscriptions und Lizenzen an. | Cloud-Subscriptions, Lizenzen | LOGIN | 2.0.0
[SophosMDM-MobileDevices.ps1](catalog/SophosMDM-MobileDevices.ps1) | **Sophos Mobile: mobile Geräte**: Liest Smartphones und Tablets über die Sophos Central API (Sophos Mobile) und legt sie als Assets an. | Assets | LOGIN | 1.0.0
<!-- catalog:end -->

**Stufe**: *LOGIN* = von LOGIN entwickelt, geprüft und supportet. *Partner* = zusammen mit einem Partner, der Partner verantwortet den Inhalt. *Community* = von Anwendern beigesteuert, von LOGIN nur auf Schadcode geprüft, kein Support.

Zurückgezogene Skripte stehen mit Grund in [`catalog/retired.json`](catalog/retired.json). Weitere Beispiele, die nicht Teil des Katalogs sind, liegen unter [`examples/`](examples/).

## Aufbau des Repos

| Ordner | Inhalt |
|---|---|
| [`catalog/`](catalog/) | Freigegebene Skripte mit Manifest, `include/` mit den Hilfsfunktionen, Zusatzordner einzelner Skripte (z.B. `CyberInsight/`) und `retired.json`. Der Aufbau entspricht genau dem `Agents`-Ordner, die Skripte laufen direkt aus dem Checkout. |
| [`examples/`](examples/) | Beispiele und Experimente, nicht Teil des Katalogs. |
| [`tools/`](tools/) | Manifest-Schema und Prüfskripte, siehe [Neues Skript aufnehmen](#neues-skript-aufnehmen). |
| `.github/` | CI-Workflow und CODEOWNERS. |

## Vorraussetzungen

**Powershell**  
Standardmäßig wird **Powershell Core "pwsh.exe"** zum Ausführen der Skripte verwendet, folglich wird eine Installation von Powershell >= 7 benötigt.
Powershell Core können Sie von [https://github.com/PowerShell/PowerShell](https://github.com/PowerShell/PowerShell) beziehen.
Nach der Installation benötigt das System einen **Neustart**, damit pwsh.exe über PATH gefunden werden kann.

Sie können auch eine andere Skript Engine verwenden, indem Sie den Parameter "engine" in der Scan-Definition nutzen.
engine | psc.exe verwendet beispielsweise die LOGINventory eigene Powershell, welche auch Zugriff auf LOGINventory Daten unterstützt, damit aber den Einschränkungen der Powershell Version 5 unterliegt.
Sie können dort jedoch auch einen Pfad angeben, z.B. zu einer anderen Powershell Version (exe).

Damit ein Skript im RemoteScanner zur Verfügung steht, muss es sich entweder in 

`INSTALLDIR\Resources\Agents`

oder in 

`%programdata%\LOGIN\LOGINventory\9.0\Agents`

befinden. Aktuell werden nur Powershell-Skripte mit der Erweiterung .ps1 unterstützt. Bei gleichem Dateinamen hat `INSTALLDIR\Resources\Agents` Vorrang. Empfohlen ist der Ordner unter `%programdata%`, weil ihn das Setup bei Updates nicht anfasst.

**Skripte herunterladen:** Laden Sie das Repository als Zip herunter ([main.zip](https://github.com/loginventory/custom-scan-agents/archive/refs/heads/main.zip)) und entpacken Sie es. Kopieren Sie aus dem Ordner `catalog` die Skripte, die Sie verwenden möchten, zusammen mit dem Ordner `include` (und bei CyberInsight dem Ordner `CyberInsight`) in eines der beiden Verzeichnisse. Sie können auch den kompletten Inhalt von `catalog` kopieren, der Aufbau ist derselbe. Eigene Skripte legen Sie daneben ab.

**Der Ordner `include` mit [`common.ps1`](catalog/include/common.ps1) und [`WebRequest.ps1`](catalog/include/WebRequest.ps1) muss immer vorhanden sein.** Bringen Sie ihn bei jedem Update eines Skripts mit auf den neuesten Stand: Die Skripte eines Katalog-Stands passen zum `include` desselben Stands.

Jetzt kann im Remote Scanner eine neue Definition vom Typ "Skriptbasierte Inventarisierung" angelegt und das entsprechende File ausgewählt werden.

Fügen Sie in der Definition auf der Seite "Parameter" die vom Skript benötigten Parameter (z.B. API-Key, Client-Secret,...) hinzu und benennen Sie die Parameter so, wie sie auch im Skript verwendet werden! Welche Parameter ein Skript erwartet, steht in seinem Manifest am Anfang der Datei.

## Skript-Manifest

Jedes Skript im Katalog beginnt mit einem Manifest-Block. Er beschreibt das Skript maschinenlesbar und ist die einzige Quelle für die Tabelle oben, für den Katalog-Index und für die Anzeige in LOGINventory (Titel, Beschreibung, Parameterformular). Für das Skript selbst ist der Block nur ein Kommentar: Ältere LOGINventory-Versionen und Skripte ohne Manifest verhalten sich wie bisher.

```powershell
<# LI-MANIFEST
{
  "schema": 1,
  "id": "jetbrains-licenses",
  "version": "2.0.0",
  "tier": "login",
  "maintainer": "Schmidt's LOGIN GmbH",
  "title":   { "de": "JetBrains Lizenzen", "en": "JetBrains licenses" },
  "summary": { "de": "Liest Produktlizenzen über die JetBrains Account API und legt sie als Cloud-Subscriptions und Lizenzen an.",
               "en": "Reads product licenses via the JetBrains Account API and creates them as cloud subscriptions and licenses." },
  "category": "cloud-licenses",
  "creates": ["Subscriptions", "Licenses"],
  "engine": "pwsh",
  "requires": { "modules": [], "permissions": ["JetBrains Account: API key and customer code"] },
  "endpoints": ["account.jetbrains.com"],
  "testRun": true,
  "parameters": [
    { "name": "apiKey",       "type": "secret", "required": true, "label": { "de": "API-Key", "en": "API key" } },
    { "name": "customerCode", "type": "string", "required": true, "label": { "de": "Kundennummer", "en": "Customer code" } }
  ]
}
#>
```

| Feld | Bedeutung |
|---|---|
| `id` | stabile Kennung, ändert sich nie |
| `version` | Skriptversion (SemVer), bei jeder Änderung erhöhen |
| `tier` | Stufe `login`, `partner` oder `community`; bei `partner` zusätzlich `partner` mit Name und URL |
| `maintainer` | verantwortliche Person, Team oder Firma |
| `title`, `summary` | Anzeige im Katalog, deutsch und englisch |
| `category` | `mdm`, `identity`, `cloud-licenses`, `security`, `import`, `other` |
| `creates` | was in LOGINventory entsteht: `Assets`, `SoftwarePackages`, `Subscriptions`, `Licenses`, `UserAccounts`, `CustomProperties`, `Vulnerabilities` |
| `engine` | `pwsh` (Standard) oder `psc` (LOGINventory PowerShell) |
| `files` | optional: Unterordner mit Zusatzdateien, z.B. `["CyberInsight/"]` |
| `requires` | benötigte PowerShell-Module (`modules`) und vorzubereitende Berechtigungen (`permissions`) |
| `endpoints` | angesprochene Hosts, als Hinweis für Firewall und Proxy |
| `testRun` | `true`, wenn das Skript ohne Nebenwirkungen laufen kann (liest nur und schreibt .inv) |
| `docs` | optional: Link zur Anleitung, deutsch und englisch |
| `parameters` | genau die Schlüssel, die das Skript über `$ctx.UserParameters` liest: `name`, `type` (`string`, `secret`, `bool`, `enum`, `int`, `path`), `required`, `default`, `options`, `label`, `help` |
| `presets` | optional: fertige Definitionen, z.B. je Aktion eine |
| `minLiVersion` | optional: kleinste LOGINventory-9-Version, mit der das Skript läuft |

Das vollständige Schema steht in [`tools/manifest.schema.json`](tools/manifest.schema.json).

## Neues Skript aufnehmen

Ein Skript kommt in `catalog/`, wenn

- der Manifest-Block vollständig und gültig ist (Beschreibung deutsch und englisch),
- es den aktuellen Header mit `New-CommonContext` nutzt ([Variante 2](#allgemeiner-skript-header-variante-2)),
- es mit dem `include` im selben Katalog-Stand läuft,
- keine Zugangsdaten und keine Testwerte (z.B. feste Computerlisten) fest eingetragen sind,
- eine verantwortliche Person, ein Team oder ein Partner benannt ist (`maintainer`).

Ablauf: Skript mit Manifest nach `catalog/` legen, lokal `tools/Test-Catalog.ps1` und `tools/Update-Readme.ps1` ausführen, Pull Request stellen. Die CI ([`.github/workflows/catalog.yml`](.github/workflows/catalog.yml)) prüft bei jedem Pull Request:

- Manifest gegen das Schema, Manifest-Block höchstens 7500 Zeichen (der Remote Scanner überträgt ihn als Ganzes),
- Parameterabgleich: Jeder Schlüssel, den das Skript aus `$ctx.UserParameters` liest, steht im Manifest, und umgekehrt,
- Stufe und [CODEOWNERS](.github/CODEOWNERS) passen zusammen (`login` und `community`: nur das LOGIN-Team; `partner`: LOGIN-Team plus Partner),
- Dateinamen bleiben stabil: Ein veröffentlichter Dateiname darf sich nicht ändern, weil Definitionen im Remote Scanner den vollen Pfad speichern. Umbenennen geht nur als "altes Skript in `retired.json` zurückziehen, neues aufnehmen",
- keine fest eingetragenen Zugangsdaten, PSScriptAnalyzer ohne Fehler,
- die Tabelle oben ist aktuell.

## Katalog-Paket

`tools/New-CatalogPackage.ps1 -CatalogVersion JJJJ.MM.n` erzeugt `scripts-catalog-<Version>.zip`: der Inhalt von `catalog/` (also genau das Layout des `Agents`-Ordners), dazu `catalog.json` (Index mit allen Manifesten und SHA-256-Hashes, aus `tools/New-CatalogIndex.ps1`) und `catalog.cat` (Windows-Katalogdatei über alle Dateien, geprüft mit `Test-FileCatalog`). Der Remote Scanner importiert dieses Paket (Datei, Firmen-Share, später online) und prüft die Hashes; eine Signatur der `catalog.cat` kommt später auf dieselbe Struktur.

Der Katalog ist als Ganzes versioniert (`JJJJ.MM.n`), weil alle Skripte dasselbe `include` teilen. Ein Release erzeugt der Workflow [`.github/workflows/release.yml`](.github/workflows/release.yml) (manuell starten, Version angeben): Er prüft den Katalog, baut das Paket und hängt Zip und `catalog.json` an das GitHub-Release `v<Version>`. Das `catalog.json` des letzten Releases ist die Referenz für die Prüfung auf stabile Dateinamen.

## Skript Umgebung

Die Datei [`catalog/include/common.ps1`](catalog/include/common.ps1) enthält Hilfsfunktionen. Sie wird über den Default Header eingebunden. Platzieren Sie diese Datei in `Agents\include`.
Die Datei [`catalog/include/WebRequest.ps1`](catalog/include/WebRequest.ps1) enthält eine Funktion zum Senden von WebRequests (inkl. Debugging, Proxy-Unterstützung und Support für Powershell 5 und 7+).

## Debug Umgebung (Visual Studio Code) ##

Für Visual Studio Code gibt es im Unterordner `.vscode` zum einen Workspacekonfigurationen für PS5 und PS7, zum anderen Startbeispiele für die Parameterübergabe, so dass die Skripte alle komplett in VS-Code getestet und anschließend 1:1 vom Scanner gesteuert werden können. Arbeitsordner ist dabei `catalog`, die Skripte finden `include` dort genauso wie später im `Agents`-Ordner.
Über den Parameter `DebugFile` wird das Schreiben aus dem Script in ein selbst anzugebendes txt-File ermöglicht. Über `Write-CommonDebug` kann man aus dem Script heraus Debug-Informationen schreiben. Wenn der Parameter im Produktivmodus dann entfernt wird, werden die Kommandos einfach ignoriert.

Um also beim Ausführen des Skripts eine Debug-Datei zu erzeugen, kann der Parameter `DebugFile` mit einem Pfad zu einer Textdatei übergeben werden, z.B. `C:/temp/mydebugfile.txt`. Alle Debug-Informationen, die mit `Write-CommonDebug` im Skript generiert werden, werden dann in diese Datei geschrieben. So können Sie die Ausführung des Skripts und die generierten Informationen einfach verfolgen und analysieren.

**Beispiel Konfiguration im launch.json**

~~~
{
    "name": "Download CyberInsight Data",
    "type": "PowerShell",
    "request": "launch",
    "script": "${workspaceFolder}/catalog/CyberInsight.ps1",
    "cwd": "${workspaceFolder}/catalog",
    "args": [
        "-parameter \"dataDir,C:/Users/Public/Documents/LOGIN/LOGINventory 9/Data#version,9.9#params,@{Action=Get;DebugFile=C:/temp/mydebugfile.txt}\""
    ]
}
~~~

dabei werden die Parameter 'dataDir' und 'version' später automatisch vom Scanner gesetzt - die Parameter in 'params' sind die, die in der Scandefinition definiert werden.

## Allgemeiner Skript-Header (Variante 1)

Dieser Header definiert einen Eingabeparameter, bindet die `common.ps1`-Datei aus dem `include`-Verzeichnis ein und initialisiert das Skript mit der `Init`-Funktion, die in `common.ps1` definiert ist. Er bleibt für bestehende eigene Skripte weiterhin gültig; neue Skripte und alle Skripte im Katalog nutzen [Variante 2](#allgemeiner-skript-header-variante-2).

```powershell
# Default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)

. (Join-Path -Path $PSScriptRoot -ChildPath "include\\common.ps1")

$scope = Init -encodedParams $parameter
# End of default header ----------------------------------------------------------------------
```

### Verwendung im Skript

Nach dem Einbinden des Headers kann man das zurückgegebene `$scope`-Objekt im Skript nutzen, um auf verschiedene konfigurierte Werte und Einstellungen zuzugreifen:

- `Parameters`: Hashtable der in der Definition hinterlegten Parameter
- `DataDir`: Pfad zum Datenverzeichnis
- `Version`: LOGINventory Version
- `TimeStamp`: Zeitstempel im Format `yyyy-MM-dd-HH-mm-ss`, zu verwenden z.B. für Zeitstempel im Dateinamen
- `TimeStamp2`: Zeitstempel im ISO 8601-Format `yyyy-MM-ddTHH:mm:ss`, zu verwenden z.B. für LastInventory.Timestamp


```powershell
# Beispiel: Zugriff auf Eigenschaften von $scope
Write-Host "Data Directory: $($scope.DataDir)"
Write-Host "Version: $($scope.Version)"
Write-Host "Parameters: $($scope.Parameters)"
Write-Host "TimeStamp: $($scope.TimeStamp)"
Write-Host "TimeStamp2: $($scope.TimeStamp2)"
```


## Allgemeiner Skript-Header (Variante 2)

Für komplexere Skripte und für die Verwendung von Debugging, ProxyConfig und der integrierten WebRequest-Funktion gibt es eine neue Art der Initialisierung, die einen umfangreicheren Kontext erzeugt, der an diese Funktionen übergeben werden kann, aber auch im eigenen Skript alle Parameter zur Verfügung stellt. Des Weiteren werden die internen Standardparameter (Proxykonfiguration, ...) primär aus der LOGINventory Konfiguration gelesen, können aber bei Bedarf über die Parameter in der Scandefinition überschrieben werden. Der Kontext hat nach der Initialisierung folgende Datenstruktur:

- **$ctx**
  - **Version**
  - **ConfigPath**
  - **LiInstallPath**
  - **ProxyConfig**
    - **Active**
    - **Url**
    - **Username**
    - **Password**
    - **UseDefaultCredentials**
  - **TimeStamp**
  - **TimeStamp2**
  - **DataDir**
  - **DebugFile**
  - **UserParameters** (enthalten alle anderen Parameter der Scandefinitionen)

~~~powershell
param([string]$parameter = "")

# Common helpers (Init/Notify/etc.)
. (Join-Path -Path $PSScriptRoot -ChildPath "include\common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "include\WebRequest.ps1")

# Build Common context (encoding, debug & proxy)
$ctx = New-CommonContext -Parameters $parameter -StartLabel 'STARTER'
~~~

### Verwendung im Skript

~~~powershell
$apiKey = $ctx.UserParameters.ApiKey
~~~

## Grundlegende Verwendung

### NewEntity

- `NewEntity -name <EntityName>`: Erstellt eine neue Entität des angegebenen Typs.

    ```powershell
    NewEntity -name "Device"
    ```

### AddPropertyValue

Fügt der aktuellen Entität Eigenschaften hinzu. Jeder Aufruf repräsentiert eine Eigenschaft der Entität mit einem spezifischen Wert.
Der erste Aufruf von AddPropertyValue wird jeweils als Key für nächstes "Element" verwendet. Das zweite Auftreten von 
SoftwarePackage.Name sorgt im Beispiel für eine weiteres Software-Paket.

- `-name <Eigenschaftsname>`: Der Name der Eigenschaft, die hinzugefügt werden soll.
- `-value <Wert>`: Der Wert der Eigenschaft.

    ```powershell
    AddPropertyValue -name "Name" -value "MyPC"
    AddPropertyValue -name "SoftwarePackage.Name" -value "MyProgram"
    AddPropertyValue -name "SoftwarePackage.Version" -value "v1"
    #neuer Eintrag durch Wiederholung des "Key Properties"
    AddPropertyValue -name "SoftwarePackage.Name" -value "MyProgram 2"
    AddPropertyValue -name "SoftwarePackage.Version" -value "v1"
    ```
So kann AddProperty einfach in einer Schleife verwendet werden

```powershell
            foreach ($item in $software) {                          
                AddPropertyValue -name "SoftwarePackage.Name" -value $($item.Name)
                AddPropertyValue -name "SoftwarePackage.Version" -value $($item.Version)
            }
```
**Achtung**: Bei einigen Werten, die im Datenmodell als "Editierbar" gekennzeichnet sind, muss beim `AddPropertyValue`-Befehl das Attribut `{Editable:true}` noch gesondert hinzugefügt werden, z.B.:

```powershell
AddPropertyValue -name "HardwareProduct.Manufacturer{Editable:true}" -value $_device.manufacturer
```

Eine vollständige Aufzählung aller betroffenen Werte findet sich in folgender Text-Datei: [EditableProperties.txt](catalog/include/EditableProperties.txt)

Falls versucht wird, eine inv-Datei in die Datenbank einzutragen, bei welcher dieses Attribut fehlt, ist folgende Fehlermeldung in der "diag.inv"-Datei ersichtlich:

```powershell
Login.Ventory.Data.Import.DataHandlerException: Error setting property HardwareProduct.Manufacturer ---&gt; System.InvalidOperationException: Editable properties cannot be implicitly overwritten
```


### WriteInv

Generiert die finale `.inv` Datei, die alle gesammelten Daten enthält.

- `-filePath <Pfad>`: Der Pfad, unter dem die Datei gespeichert werden soll.
- `-version <Version>`: Die Version des Datensatzes oder des Erhebungsprozesses.

### Benachrichtigung an den RemoteScanner JobMonitor

- `Write-Host <Nachricht>`: Kann für einfache Benachrichtigungen verwendet werden.
- `Notify -name <Thema> -itemName <Key> -itemResult <ItemResult> -message <Nachricht> -category <EventCategory> -state <State>`: Sendet detaillierte Nachrichten an den Jobmonitor des RemoteScanners. Ermöglicht das Übermitteln zusätzlicher Informationen wie Kategorie und Zustand sowie Ergebnis der Nachricht. -name ist der Key des Events. Werden meherer Events mit gleichem Name gesendet, werden diese im JobMonitor überschrieben bzw. aktualisiert.

## EventCategory und State

### EventCategory

Definiert die Art der Nachricht, die gesendet wird:

- `None`: Keine spezifische Kategorie.
- `Verbose`: Ausführliche Informationen für Debugging-Zwecke.
- `Info`: Allgemeine Informationen.
- `Warning`: Warnungen, die auf potenzielle Probleme hinweisen.
- `Error`: Fehlermeldungen.

### State

Gibt den Zustand des Vorgangs an:

- `None`: Kein spezifischer Zustand.
- `Canceled`: Der Prozess wurde abgebrochen.
- `Faulty`: Der Prozess hat einen Fehler festgestellt.
- `Aborted`: Der Prozess wurde vorzeitig beendet.
- `Finished`: Der Prozess wurde erfolgreich abgeschlossen.
- `Calculating`: Der Prozess befindet sich in der Berechnungsphase.
- `Detecting`: Der Prozess ist in der Erkennungsphase.
- `Queued`: Der Prozess wurde in die Warteschlange eingereiht.
- `Executing`: Der Prozess wird gerade ausgeführt.

### ItemResult

Gibt das Ergebins des Vorgans/Elements an:

- `None`: Keine spezifisches Ergebnis.
- `Canceled`: Der Vorgang wurde abgebrochen.
- `Excluded`: Das Element wurde ausgeschlossen.
- `Error`: Bei dem Vorgang/Element ist ein Fehler aufgetreten.
- `Ok`: Erfolgreich.

## Nutzungshinweise

- Beginnen Sie die Datenerhebung mit `NewEntity -name <NameDerEntität>`, um den korrekten Entitätstyp zu definieren.
- Verwenden Sie `AddPropertyValue`, um alle relevanten Daten für eine Entität festzulegen.
- Nutzen Sie `Write-Host` für einfache Benachrichtigungen oder `Notify` für detailliertere Benachrichtigungen mit zusätzlichen Informationen wie Kategorie und Zustand.

Diese Dokumentation bietet einen Überblick über die Verwendung des Skripts im Kontext von LOGINventory und RemoteScanner. Es ist wichtig, die spezifischen Anforderungen und Strukturen der LOGINventory-Umgebung zu verstehen, um das Skript effektiv einzusetzen.
