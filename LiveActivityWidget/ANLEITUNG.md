# Live Activity einrichten (einmalig, ~2 Minuten in Xcode)

Die App-Seite ist fertig (Activity wird bei Wiedergabe gestartet/aktualisiert,
`NSSupportsLiveActivities` ist gesetzt). Sichtbar wird sie erst mit einem
Widget-Extension-Target:

1. Xcode → **File → New → Target… → iOS → Widget Extension**
   - Product Name: `HoerregalWidgets`
   - ✅ **Include Live Activity**, ❌ Configuration App Intent (nicht nötig)
   - Embed in: `ABSPlayer`
   - Bei der Nachfrage „Activate scheme?" → egal (Cancel reicht)
2. Die von Xcode generierten Dateien im neuen Ordner `HoerregalWidgets/`
   **löschen** (nur `Info.plist` und ggf. Assets behalten) und stattdessen
   `LiveActivityWidget/HoerregalLiveActivity.swift` dem neuen Target hinzufügen
   (Datei markieren → File Inspector → Target Membership ✅ HoerregalWidgets).
3. `Sources/Models/PlaybackActivityAttributes.swift` markieren → File
   Inspector → Target Membership: zusätzlich ✅ `HoerregalWidgets`
   (die Datei gehört App UND Extension).
4. Deployment Target der Extension auf iOS 17 stellen (wie die App).
5. Auf dem GERÄT testen: Buch abspielen → sperren → Live Activity auf dem
   Lock Screen; auf iPhones mit Dynamic Island auch dort.

Hinweis: Läuft die App im Simulator, erscheinen Live Activities dort nur
eingeschränkt — echtes Gerät verwenden.
