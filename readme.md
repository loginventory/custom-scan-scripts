# Skriptbasierte Inventarisierung mit LOGINventory

Diese Dokumentation beschreibt die Verwendung und Funktionen des Skripts, das von der RemoteScanner-Komponente von LOGINventory aufgerufen wird, wenn der Definitionstyp "Skriptbasierte Inventarisierung" ausgewählt wird. Es ermöglicht die dynamische Erstellung von Inventardatensätzen durch Übergabe von Argumenten durch den RemoteScanner.

Damit ein Skript im RemoteScanner zur Verfügung steht, muss es sich entweder in 

`%processdir%\Resources\Agents` (ProcessDir ist das Ausführungsverzeichnis der LOGINquirySvc.exe)

oder in 

`%programdata%\LOGIN\LOGINventory\9.0\Agents`

befinden. Akutell werden nur Powershell-Skripte mit der Erweiterungen .ps1 unterstützt.

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

### AddPropertyValue

Fügt Eigenschaften zur aktuellen Entität hinzu.

- `-name <Eigenschaftsname>`: Der Name der Eigenschaft, die hinzugefügt werden soll.
- `-value <Wert>`: Der Wert der Eigenschaft.

### WriteInv

Generiert die finale `.inv` Datei, die alle gesammelten Daten enthält.

- `-filePath <Pfad>`: Der Pfad, unter dem die Datei gespeichert werden soll.
- `-version <Version>`: Die Version des Datensatzes oder des Erhebungsprozesses.

### Benachrichtigung an den RemoteScanner JobMonitor

- `Write-Host <Nachricht>`: Kann für einfache Benachrichtigungen verwendet werden.
- `Notify -name <Thema> -itemName <Key> -message <Nachricht> -category <EventCategory> -state <State>`: Sendet detaillierte Nachrichten an den Jobmonitor des RemoteScanners. Ermöglicht das Übermitteln zusätzlicher Informationen wie Kategorie und Zustand der Nachricht. -itemName ist der Key des Events. Werden meherer Events mit gleichem ItemName gesendet, werden diese im JobMonitor überschrieben bzw. aktualisiert.

## EventCategory und State

### EventCategory

Definiert die Art der Nachricht, die gesendet wird:

- `None`: Keine spezifische Kategorie.
- `Verbose`: Ausführliche Informationen für Debugging-Zwecke.
- `Info`: Allgemeine Informationen.
- `Warning`: Warnungen, die auf potenzielle Probleme hinweisen.
- `Error`: Fehlermeldungen.

### State

Gibt den Zustand des Prozesses an:

- `None`: Kein spezifischer Zustand.
- `Canceled`: Der Prozess wurde abgebrochen.
- `Faulty`: Der Prozess hat einen Fehler festgestellt.
- `Aborted`: Der Prozess wurde vorzeitig beendet.
- `Finished`: Der Prozess wurde erfolgreich abgeschlossen.
- `Calculating`: Der Prozess befindet sich in der Berechnungsphase.
- `Detecting`: Der Prozess ist in der Erkennungsphase.
- `Queued`: Der Prozess wurde in die Warteschlange eingereiht.
- `Executing`: Der Prozess wird gerade ausgeführt.

## Nutzungshinweise

- Beginnen Sie die Datenerhebung mit `NewEntity -name <NameDerEntität>`, um den korrekten Entitätstyp zu definieren.
- Verwenden Sie `AddPropertyValue`, um alle relevanten Daten für eine Entität festzulegen.
- Nutzen Sie `Write-Host` für einfache Benachrichtigungen oder `Notify` für detailliertere Benachrichtigungen mit zusätzlichen Informationen wie Kategorie und Zustand.

Diese Dokumentation bietet einen Überblick über die Verwendung des Skripts im Kontext von LOGINventory und RemoteScanner. Es ist wichtig, die spezifischen Anforderungen und Strukturen der LOGINventory-Umgebung zu verstehen, um das Skript effektiv einzusetzen.
