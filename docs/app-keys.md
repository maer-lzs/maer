# App-Schlüssel & Bau-Hygiene

**Politik:** Schlüsselwerte (Jamendo `client_id`, PodcastIndex Key+Secret) liegen
NIE im Repo — im offenen Code stehen nur leere Platzhalter. Die injizierten
Schlüssel authentifizieren die **App** gegenüber dem Dienst und tragen keine
Nutzerkennung. Ein vom Nutzer eingetragener eigener Schlüssel schlägt den
injizierten immer (`AppStorageKeys.resolvedAppKey`, eine Regel für beide Dienste);
ohne beide verhält sich die App wie bisher (Reihe entfällt still bzw. iTunes-Fallback).

**Bau-Ort:** `Config/AppKeys.local.xcconfig` (gitignored) mit
`MAER_JAMENDO_CLIENT_ID` / `MAER_PODCASTINDEX_KEY` / `MAER_PODCASTINDEX_SECRET`.
Die committete `Config/AppKeys.xcconfig` (Base-Konfiguration des App-Targets)
inkludiert sie optional und hält leere Defaults; `Maer-Info.plist`
substituiert die Werte in die InfoDictionary-Schlüssel `JamendoClientId` /
`PodcastIndexKey` / `PodcastIndexSecret`. Beide Config-Dateien sind per
membershipException vom Ressourcen-Sweep des synchronisierten Root-Ordners
ausgenommen (die lokale Datei darf nicht ins Bundle kopiert werden).

# Bundle-Hygiene: was ausgeliefert wird

Der synchronisierte Root-Ordner des App-Targets ist das **Repo-Wurzelverzeichnis**.
Sein Ressourcen-Sweep nimmt daher alles mit, was nicht Quelle ist — und kompiliert
zusätzlich die Unit-Test-Dateien ins App-Binary (gemessen: alle 72 Testdateien
`in target 'Maer'`, 84 Bundle-Dateien, davon 53 Test-Fixtures, 8 interne
Dokumente, 7 Screenshots und `.claude/settings.local.json`).

**Gelöst an der Wurzel (e885a01):** Die synchronisierte Gruppe des App-Targets
trägt jetzt `path = Sources`. Damit liegt das Repo-Wurzelverzeichnis — Doku,
Screenshots, Test-Korpora, Werkzeug-Konfiguration **und die Projektdatei selbst**
— außerhalb des eingesammelten Bereichs. Was die App wirklich aus der Wurzel
braucht, ist explizit verankert: `Assets.xcassets` und `LICENSE` (bewusst
mitgeliefert, GPL) in der Ressourcen-Phase; `Maer-Info.plist` und
`Maer.entitlements` hängen ohnehin an Bau-Einstellungen. Die Widget-Quellen
unter `LiveActivityWidget/` haben eine eigene synchronisierte Gruppe bekommen.

Die frühere Ausnahmeliste des App-Targets (13 Einträge) und die
`EXCLUDED_SOURCE_FILE_NAMES`-Muster waren die Symptombehandlung dieser Wurzel und
sind entfallen. Zwei Eigenheiten bleiben dokumentiert, weil sie beim Umbau
gemessen wurden: **Verzeichniseinträge in `membershipExceptions` wirken nicht**
(Xcode entfernt sie sogar selbst wieder aus der Projektdatei), und `*` überspringt
in den Mustern kein `/`.

`LICENSE` bleibt bewusst im Bundle (GPL-3.0).

Wachhund: `MaerTests/ProjectFileIntegrityTests` prüft in jeder Beleg-Kette,
dass die Projektdatei keine Selbstreferenz trägt (Xcode injiziert sie automatisch,
sobald das Projekt offen ist und sich der Baum darunter ändert) und dass die
Schlüsseldatei nie Bundle-Mitglied wird.
