# App-Schlüssel: Politik + Bau-Ort

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
