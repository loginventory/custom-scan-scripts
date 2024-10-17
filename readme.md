# Skriptbasierte Inventarisierung mit LOGINventory

Mit der skriptbasierten Inventarisierung ist es möglich über den LOGINventory Remote Scanner eigene Skripte zur erzeugung dynamischer Inventardatenzätze zu erzeugen. Hierfür steht der Definitionstyp "Skriptbasierte Inventarisierung" zur Verfügung.
In diesem Definitionstyp können Parameter hinterlegt werden, welche an die Skripte übergeben werden und somit dort zur Verfügung stehen. Ziel ist es eine .inv Datei im Datenverzeichnis zu erzeugen, welche mittels LOGINsert.exe in die LOGINventory Datenbank eingetragen wird.
Diese .inv Dateien sind XML Dateien, welche ein LOGINventory konformes Schema aufweisen müssen. Um die Handhabung zu vereinfachen, kann in den Skripten eine vereinfachte Syntax -name "Tabellle.Eigenschaft" -value "Wert" verwendet werden (siehe [Grundlegende Verwendung](#grundlegende-verwendung)). 

In [diesem Beispiel](step-by-step-example.md) zeigen wir die **exemplarische Verwendung** der skriptbasierten Inventarisierung zum **Anlegen von Assets in LOGINventory durch die Inventarisierung des Azure-Active-Directory**.

Bei Pfadangaben gilt: "INSTALLDIR" entspricht Ihrem LOGINventory Installationsverzeichnis. Sollte ein hier erwähntes Verzeichnis lokal noch nicht existieren, erstellen Sie dieses. Diese Struktur wird nicht durch das LOGINventory Setup angelegt.

## Übersicht über verfügbare Skripte

Die folgenden Skripte sind aktuell Teil des Github Repos:

Skript | Beschreibung
-------|-------------
[AzureAd-Devices-Compliant.ps1](AzureAd-Devices-Compliant.ps1)|Dieses Skript verwendet Microsoft Graph, um Informationen über Geräte in Microsoft Intune und Azure Active Directory abzurufen. Es liest unter anderem den Compliant Status der Geräte aus und erzeugt für diesen eine Eigene Eigenschaft (Compliant), welche dann in LOGINventory zur Verfügung steht.
[Device-Software-WMI.ps1](Device-Software-WMI.ps1)|Dieses Skript verwendet Windows Management Instrumentation (WMI), um Informationen über installierte Software von angegebenen Computern abzurufen.
[csv-user-import.ps1](csv-user-import.ps1)|Dieses Skript öffnet liest aus einer csv-Datei Informationen zu vorhandenen Usern und legt diese in LOGINventory an.
[jetbrains.ps1](jetbrains.ps1)|Dieses Skript ruft Informationen zu JetBrains Produktlizenzen ab, indem es die vom Softwareherssteller JetBrains die Account API anfragt.


## Vorraussetzungen

**Powershell**  
Standardmäßig wird **Powershell Core "pwsh.exe"** zum ausführen der Skripte verwendet, folglich wird eine Installation von Powershell >= 7 benötigt.
Powershell Core können Sie von [https://github.com/PowerShell/PowerShell] beziehen.
Nach der Installation benötigt das System einen **Neustart**, damit pwsh.exe über PATH gefunden werden kann.

Sie können auch eine andere Skript Engine verwenden indem Sie den Parameter "engine" in der Scan-Definition nutzen.
engine | pcs.exe verwendet beispielsweise die LOGINventory eigene Powershell, welche auch Zugriff auf LOGINventroy Daten unterstützt unterliegt damit aber den Einschränkungen der Powershell Version 5.
Sie können dort jedoch auch einen Pfad angeben, z.B. zu einer anderen Powershell Version (exe).

Damit ein Skript im RemoteScanner zur Verfügung steht, muss es sich entweder in 

`INSTALLDIR\Resources\Agents`

oder in 

`%programdata%\LOGIN\LOGINventory\9.0\Agents`

befinden. Akutell werden nur Powershell-Skripte mit der Erweiterungen .ps1 unterstützt.

Laden Sie sich hier aus diesem Repository die Skripte herunter, die Sie verwenden möchten oder nutzen Sie selbstgeschriebene Skripte. Positionieren Sie diese in einem der beiden Verzeichnisse und prüfen Sie, dass sich dort auch der Unterordner "include" mit der Datei `common.ps1` befindet!

Jetzt kann im Remote Scanner eine neue Definition vom Typ "Skriptbasierte Inventarisierung" angelegt und das entsprechende File ausgewählt werden.

Fügen Sie in der Definition auf der Seite "Parameter" die vom Skript benötigten Parameter (z.B. API-Key, Client-Secret,...) hinzu und benennen Sie die Parameter so, wie sie auch im Skript verwendet werden!

## Skript Umgebung

Die Datei include\common.ps1 enthält Hilfsfunktionen. Sie wird über den Default Header eingebunden. Platzieren Sie diese Datei in Agents\include.

## Allgemeiner Skript-Header

Dieser Header definiert einen Eingabeparameter, bindet die `common.ps1`-Datei aus dem `include`-Verzeichnis ein und initialisiert das Skript mit der `Init`-Funktion, die in `common.ps1` definiert ist. Stellen Sie sicher, dass Sie den allgemeinen Header in jedes der PowerShell-Skripte integrieren, um eine konsistente Initialisierung und Einbindung gemeinsamer Ressourcen zu gewährleisten.

```powershell
# Default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)

. (Join-Path -Path $PSScriptRoot -ChildPath "include\\common.ps1")

$scope = Init -encodedParams $parameter
# End of default header ----------------------------------------------------------------------
```

## Verwendung im Skript

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

Eine vollständige Aufzählung aller betroffenen Werte findet sich in folgender Text-Datei: [EditableProperties.txt](include/EditableProperties.txt)

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
