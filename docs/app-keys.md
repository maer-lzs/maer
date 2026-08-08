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
inkludiert sie optional und hält leere Defaults; `ABSPlayer-Info.plist`
substituiert die Werte in die InfoDictionary-Schlüssel `JamendoClientId` /
`PodcastIndexKey` / `PodcastIndexSecret`. Beide Config-Dateien sind per
membershipException vom Ressourcen-Sweep des synchronisierten Root-Ordners
ausgenommen (die lokale Datei darf nicht ins Bundle kopiert werden).

# Bundle-Hygiene: was ausgeliefert wird

Der synchronisierte Root-Ordner des App-Targets ist das **Repo-Wurzelverzeichnis**.
Sein Ressourcen-Sweep nimmt daher alles mit, was nicht Quelle ist — und kompiliert
zusätzlich die Unit-Test-Dateien ins App-Binary (gemessen: alle 72 Testdateien
`in target 'ABSPlayer'`, 84 Bundle-Dateien, davon 53 Test-Fixtures, 8 interne
Dokumente, 7 Screenshots und `.claude/settings.local.json`).

Ausschluss über `EXCLUDED_SOURCE_FILE_NAMES` in `Config/App.xcconfig` (Basis-
Konfiguration des App-Targets, inkludiert `AppKeys.xcconfig`). Zwei gemessene
Eigenheiten: **Verzeichniseinträge in `membershipExceptions` wirken nicht** (Xcode
entfernt sie sogar wieder aus der Projektdatei) — nur Dateien; und `*` überspringt
kein `/`, deshalb ein Muster je Tiefe. Der Musterweg deckt auch künftig neu
hinzukommende Dateien ab, die Datei-für-Datei-Ausnahme nicht.

`LICENSE` bleibt bewusst im Bundle (GPL-3.0).

Wachhund: `ABSPlayerTests/ProjectFileIntegrityTests` prüft in jeder Beleg-Kette,
dass die Projektdatei keine Selbstreferenz trägt (Xcode injiziert sie automatisch,
sobald das Projekt offen ist und sich der Baum darunter ändert) und dass die
Schlüsseldatei nie Bundle-Mitglied wird.
