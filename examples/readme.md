# Beispiele

Die Skripte in diesem Ordner sind **nicht Teil des Katalogs** (`catalog/`). Sie zeigen Techniken
oder dienen als Vorlage für eigene Skripte und werden nicht von der CI geprüft.

Um ein Beispiel auszuführen, kopieren Sie es neben einen `include`-Ordner mit `common.ps1` und
`WebRequest.ps1`, also z.B. nach `catalog/` im Checkout oder in den `Agents`-Ordner der
skriptbasierten Inventarisierung.

| Skript | Beschreibung |
|---|---|
| [Device-Software-WMI.ps1](Device-Software-WMI.ps1) | Liest installierte Software mehrerer Computer per WMI (`Win32_Product`) und schreibt je Computer eine .inv-Datei. Die Computerliste steht fest im Skript; `Win32_Product` löst auf jedem Zielrechner eine MSI-Konsistenzprüfung aus und ist deshalb nur als Beispiel gedacht. |
