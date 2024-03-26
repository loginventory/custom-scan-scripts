# Schritt für Schritt Anleitung zur Verwendung der Skriptbasierten Inventarisierung in LOGINventory

## Exemplarische Vorgehensweise am Beispiel des Skripts `AzureAd-Devices-Compliant.ps1` zur Erfassung von Azure-Active-Directory Geräten und deren Compliant Status

*Der Compliant Status ist insbesondere in Verbindung mit dem Einsatz von Microsoft Intune interessant.*

### Generelle Vorbereitung:

1. Laden Sie die für Ihr System passende Powershell Core Version von [PowerShell GitHub](https://github.com/PowerShell/PowerShell) herunter und installieren Sie diese. **Wichtig:** Die in Windows enthaltene Powershell Version (5.x) ist nicht ausreichend.
2. Starten Sie das System neu.
3. Aktivieren Sie den LOGINventory Beta-Modus [hier](https://www.loginventory.info/documentation/9/de/technische-details/#aktivieren-des-beta-modus).
4. Besuchen Sie das [LOGINventory Custom-Scan-Scripts GitHub Repository](https://github.com/loginventory/custom-scan-scripts).
5. Laden Sie die common.ps1 aus dem `include` Ordner herunter und kopieren Sie diesen nach `C:\ProgramData\LOGIN\LOGINventory\9.0\Agents\include`.
   Sollte ein hier erwähntes Verzeichnis lokal noch nicht exsistieren, erstellen Sie dieses. Diese Struktur wird nicht durch das LOGINventory Setup angelegt.

### Vorbereitung für dieses Skript:

1. Laden Sie die Datei `AzureAd-Devices-Compliant.ps1` herunter und kopieren Sie diese nach `C:\ProgramData\LOGIN\LOGINventory\9.0\Agents`.
2. Installieren Sie die nötigen Powershell Module über die Powershell:

```
Install-Module Microsoft.Graph
Install-Module Microsoft.Graph.Authentication
Install-Module Microsoft.Graph.Users
```
3. Starten Sie die LOGINventory Konsole, wählen Sie *Remote Scanner*, *Definitionen*, *Neu* -> *Skriptbasierte Inventarisierung*.
4. Wählen Sie unter *Skript* das entsprechende Skript (`AzureAd-Devices-Compliant`) aus und wechseln Sie zum Tab *Parameter*.

#### Parameter:

- Im Skript Header von `AzureAd-Devices-Compliant.ps1` finden Sie unter dem Punkt *Parameter* beschrieben, welche Parameter das Skript entgegen nimmt.
- In unserem Fall benötigen Sie die Zugangsdaten zu Ihrer Azure App Registration (siehe [Handbuch](https://www.loginventory.info/documentation/9/de/technische-details/#konfigurieren-einer-app-registrierung-bei-microsoft-azure)) also `tenantId`, `clientId` und `clientSecret`. Optional können Sie hier noch einen Namensfilter angeben.
- Natürlich steht es Ihnen frei, das Skript zu erweitern und eigene Parameter zu übergeben und auf deren Basis die Inventarisierung zu erweitern bzw. andere Aktion auszuführen (E-Mail senden etc.).

Hinterlegen Sie die benötigten Schlüssel-Wert-Paare (`tenantId`, `clientId`, `clientSecret`) ein und aktivieren Sie bei `clientSecret` bei Bedarf die *Passwort Checkbox*.

Schließen Sie den Dialog und starten Sie die neu erstellte Definition.

Im *Job Monitor* sollten Sie nun entsprechende Statusmeldungen erhalten. Ist der Scan beendet und die Datenverarbeitung durch LOGINsert abgeschlossen, finden Sie die inventarisierten Devices in der *Assets*-Abfrage in der LOGINventory Konsole.
