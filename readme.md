# LOGINventory UniversalAgentInventory Skript-Dokumentation

Diese Dokumentation beschreibt die Verwendung und Funktionen des Skripts, das von der RemoteScanner-Komponente von LOGINventory aufgerufen wird, wenn der Definitionstyp "UniversalAgentInventory" ausgewählt wird. Es ermöglicht die dynamische Erstellung von Inventardatensätzen durch Übergabe von Argumenten durch den RemoteScanner.

Damit ein Skript im RemoteScanner zur Verfügung steht, muss es sich entweder in 

%processdir%\Resources\Agents (ProcessDir ist das Ausführungsverzeichnis der LOGINquirySvc.exe)

oder in 

%programdata%\LOGIN\LOGINventory\9.0\Agents

befinden.

## Allgemeiner Skript-Header
Jedes Skript sollte den folgenden Standard-Header enthalten, der grundlegende Initialisierungen und das Einbinden gemeinsamer Ressourcen wie die `common.ps1`-Bibliothek vornimmt.

```powershell
# Default header ----------------------------------------------------------------------
param (
    [string]$parameter = ""
)

. (Join-Path -Path $PSScriptRoot -ChildPath "include\\common.ps1")

$scope = Init -encodedParams $parameter
# End of default header ----------------------------------------------------------------------
```

Dieser Header definiert einen Eingabeparameter, bindet die `common.ps1`-Datei aus dem `include`-Verzeichnis ein und initialisiert das Skript mit der `Init`-Funktion, die in `common.ps1` definiert ist.

## Verwendung im Skript

Nach dem Einbinden des Headers kann man das zurückgegebene `$scope`-Objekt im Skript nutzen, um auf verschiedene konfigurierte Werte und Einstellungen zuzugreifen:

- `Credentials`: Hashtable der Credentials
- `Parameters`: Hashtable der Parameter
- `DataDir`: Pfad zum Datenverzeichnis
- `Version`: LOGINventory Version
- `TimeStamp`: Zeitstempel im Format `yyyy-MM-dd-HH-mm-ss`, zu verwenden z.B. für Zeitstempel im Dateinamen
- `TimeStamp2`: Zeitstempel im ISO 8601-Format `yyyy-MM-ddTHH:mm:ss`, zu verwenden z.B. für LastInventory.Timestamp


```powershell
# Zugriff auf Eigenschaften von $scope
Write-Host "Data Directory: $($scope.DataDir)"
Write-Host "Version: $($scope.Version)"
Write-Host "Parameters: $($scope.Parameters)"
Write-Host "Credentials: $($scope.Credentials)"
Write-Host "TimeStamp: $($scope.TimeStamp)"
Write-Host "TimeStamp2: $($scope.TimeStamp2)"
```

Stellen Sie sicher, dass Sie den allgemeinen Header in jedes der PowerShell-Skripte integrieren, um eine konsistente Initialisierung und Einbindung gemeinsamer Ressourcen zu gewährleisten.

## Grundlegende Verwendung

1. **SetEntityName**: Bevor neue Entitäten (Einträge) hinzugefügt werden, muss eine Entität mit `SetEntityName` gesetzt werden. Dies definiert den Typ der zu erstellenden Entität.
2. **NewEntity**: Mit `NewEntity` wird ein neuer Datensatz angelegt. Dieser Schritt folgt direkt nach dem Setzen des Entitätsnamens.
3. **AddPropertyValue**: Nachdem eine neue Entität erstellt wurde, werden deren Eigenschaften mit `AddPropertyValue` gesetzt. Hiermit werden die spezifischen Daten für die Entität definiert.
4. **WriteInv**: Schließlich erzeugt `WriteInv` eine LOGINventory `.inv` Datei, die in das Datenverzeichnis (`datadir`) geschrieben wird. Diese Datei enthält die gesammelten Inventardaten.
5. **Notify**: Mit `Notify` können Nachrichten in den Jobmonitor des RemoteScanners geschrieben werden. Dies ist nützlich für Feedback und Statusupdates während der Ausführung des Skripts.

## Methoden und ihre Parameter

Im Folgenden finden Sie die im Skript verwendeten Methoden und eine Erklärung ihrer Parameter:

### SetEntityName

- `-name`: Legt den Namen der Entität fest, die erstellt werden soll. Dies definiert den Typ der zu erfassenden Daten.

### NewEntity

Erstellt eine neue Instanz der zuvor mit `SetEntityName` definierten Entität. Diese Methode hat keine Parameter und wird aufgerufen, um den Beginn eines neuen Datensatzes zu signalisieren.

### AddPropertyValue

Fügt Eigenschaften zur aktuellen Entität hinzu.

- `-name`: Der Name der Eigenschaft, die hinzugefügt werden soll.
- `-value`: Der Wert der Eigenschaft.

### WriteInv

Generiert die finale `.inv` Datei, die alle gesammelten Daten enthält.

- `-filePath`: Der Pfad, unter dem die Datei gespeichert werden soll.
- `-version`: Die Version des Datensatzes oder des Erhebungsprozesses.

### Notify

Sendet Nachrichten an den Jobmonitor des RemoteScanners.

- `-name`: Ein eindeutiger Name für den Nachrichtenkontext.
- `-itemName`: Der Name des betroffenen Elements.
- `-message`: Die Nachricht, die gesendet werden soll.
- `-category`: Die Kategorie der Nachricht (`None`, `Verbose`, `Info`, `Warning`, `Error`).
- `-state`: Der Zustand des Prozesses (`None`, `Canceled`, `Faulty`, `Aborted`, `Finished`, `Calculating`, `Detecting`, `Queued`, `Executing`).


## Kategorien und Zustände

Das Skript verwendet bestimmte Kategorien (`EventCategory`) und Zustände (`State`), um den Typ der Nachricht und den Zustand des Prozesses an den Jobmonitor zurückzugenben. Diese Aufrufe sind rein informativ.

### EventCategory

- `None`: Keine spezifische Kategorie.
- `Verbose`: Ausführliche Informationen für Debugging-Zwecke.
- `Info`: Allgemeine Informationen.
- `Warning`: Warnungen, die auf potenzielle Probleme hinweisen.
- `Error`: Fehlermeldungen.

### State

- `None`: Kein spezifischer Zustand.
- `Canceled`: Der Prozess wurde abgebrochen.
- `Faulty`: Der Prozess hat einen Fehler festgestellt.
- `Aborted`: Der Prozess wurde vorzeitig beendet.
- `Finished`: Der Prozess wurde erfolgreich abgeschlossen.
- `Calculating`: Der Prozess befindet sich in der Berechnungsphase.
- `Detecting`: Der Prozess ist in der Erkennungsphase.
- `Queued`: Der Prozess wurde in die Warteschlange eingereiht.
- `Executing`: Der Prozess wird gerade ausgeführt.

## Erweiterte Nutzung und Skriptbeispiel

Das bereitgestellte Skriptbeispiel demonstriert die praktische Anwendung der oben beschriebenen Methoden. Es umfasst den Datenerhebung und -verarbeitung, sowie die Erstellung und das Schreiben der `.inv` Datei.

### Beispiel

```powershell
SetEntityName -name "Device"
...
NewEntity
AddPropertyValue -name "Name" -value $entry.DisplayName
...
WriteInv -filePath $filePath -version $version
```

## Nutzungshinweise

- Stellen Sie sicher, dass `SetEntityName` vor `NewEntity` aufgerufen wird, um den korrekten Entitätstyp zu definieren.
- Verwenden Sie `AddPropertyValue` umfassend, um alle relevanten Daten für eine Entität festzulegen.
- Nutzen Sie `Notify` zur Kommunikation mit dem RemoteScanner, insbesondere um den Fortschritt oder Probleme während der Ausführung zu melden.

Diese umfassende Dokumentation bietet einen detaillierten Überblick über die Struktur und Funktionsweise des Skripts, einschließlich des erforderlichen Standard-Headers und der verwendeten Methoden, um eine standardisierte Datenerfassung und -verarbeitung in der LOGINventory-Umgebung zu gewährleisten.
