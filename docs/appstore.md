# App-Store-Checkliste für Mär

Stand: gemessen am Kandidaten 3.5 (Build 55), 19.10.2026. Jede Zeile nennt,
woran sie gemessen ist; was nicht im Repository steht, nennt, wer es klärt.

## Konto und Kennungen

- [x] **Apple Developer Program:** die TestFlight-Builds sind mit dem
      bezahlten Team signiert und hochgeladen.
- [x] **Bundle-IDs** (`Maer.xcodeproj`): App `fm.maer.app`, Widget
      `fm.maer.app.widgets`; die Testziele `fm.maer.app.tests` und
      `fm.maer.app.uitests` gehen nicht in den Store.
- [x] **Fähigkeiten** (`Maer.entitlements`, `MaerWidgets.entitlements`):
      App-Gruppe `group.fm.maer.app` (App und Widget), iCloud mit CloudKit im
      Container `iCloud.fm.maer.app`, Key-Value-Store
      `$(TeamIdentifierPrefix)fm.maer.app`, CarPlay Audio, Push
      (`aps-environment` steht in der Datei auf `development`; für den Store
      setzt das Verteilungsprofil den Wert, am Archiv nicht gemessen).
- [ ] **CloudKit-Schema in Production:** die Datensatztypen entstehen nur in
      Development, TestFlight und Store laufen gegen Production. Vor der
      Einreichung in der CloudKit-Konsole prüfen, dass die vier Typen der App
      dort stehen (`Stand`, `Stats`, `Playlist`, `Choice`), sonst
      **Deploy Schema Changes**.

## Im Code (gemessen am Kandidaten)

- [x] **Version:** `MARKETING_VERSION = 3.5`, `CURRENT_PROJECT_VERSION = 55`
      an allen acht Stellen.
- [x] **App-Icon:** `Assets.xcassets/AppIcon.appiconset` trägt eine Grafik
      1024 × 1024 ohne Alphakanal, dazu die dunkle und die getönte Fassung
      (beide aus derselben dunklen Datei).
- [x] **Kategorie:** `LSApplicationCategoryType` ist
      `public.app-category.books`.
- [x] **Privacy-Manifest** (`Sources/PrivacyInfo.xcprivacy`): kein Tracking,
      keine Tracking-Domains, keine erfassten Daten. Schnittstellen mit
      Grund: UserDefaults (`CA92.1`), freier Speicherplatz (`E174.1`:
      `volumeAvailableCapacityForImportantUsage` in `DownloadManager.swift`
      und `ImageCache.swift`) und Zeitstempel von Dateien im eigenen
      Container (`C617.1`: `contentModificationDate` in denselben zwei
      Dateien, `.modificationDate` in `ImageCache.swift`). Ohne Grund für
      eine gerufene Kategorie nimmt App Store Connect die Einreichung nicht
      an. Das Widget ruft keine dieser Schnittstellen und braucht kein
      eigenes Manifest. Der Zaun `PrivacyManifestFenceTests` hält beide
      Ziele in beiden Richtungen gegen ihre Quellen.
- [x] **App Transport Security:** `Maer-Info.plist` trägt
      `NSAllowsArbitraryLoads = true` und keinen feineren Schlüssel daneben
      (Apple ignoriert den globalen, sobald `…ForMedia`, `…InWebContent` oder
      `NSAllowsLocalNetworking` mit im Wörterbuch steht; gemessen 19.09.2026).
      Der Zaun `TransportSecurityFenceTests` hält den Schlüssel so. Die
      Begründung für den Prüfer steht in den Review-Notes unten.
- [ ] **Export-Kennzeichnung:** `ITSAppUsesNonExemptEncryption` steht auf
      NO. Die App verschlüsselt über HTTPS hinaus selbst, mit CryptoKit des
      Systems: die Sitzung zum Mär-Sync-Dienst (`NoiseNK.swift`), die
      versiegelten Logins von Premium-Feeds (`FeedAuthCrypto.swift`) und die
      Anmeldung beim Dienst (`SignInDerivation.swift`). Ob NO trägt, klärt
      die Rechtsfrage vor der Einreichung.
- [x] **Keine Bezahlung:** kein In-App-Kauf; StoreKit steht nur in
      `MetricReceiver.swift` für `AppTransaction` (ob TestFlight oder Store
      signiert hat).
- [x] **App-Schlüssel:** `JamendoClientId`, `PodcastIndexKey` und
      `PodcastIndexSecret` kommen aus `Config/AppKeys.local.xcconfig`; im
      geteilten Baum, aus dem archiviert wird, sind alle drei gesetzt (nur
      die Namen geprüft).
- [x] **Demo-Zugang nur in den Prüfhinweisen:** der frühere Knopf „Use Demo
      Server“ ist zurückgebaut; er stand jedem Nutzer offen und sein Token
      stand im Klartext im Quelltext. Serveradresse und Token gehören in die
      App-Review-Informationen von App Store Connect („Anmeldedaten
      erforderlich“), nicht in die App.

## App Store Connect

- [ ] **App anlegen:** Name „Mär“ (ob frei, ist nicht geprüft; einen
      Ersatz schlägt der Entwurf der Store-Texte vor), Primärsprache Deutsch,
      Kategorie Bücher wie im Code.
- [ ] **Preis und Verfügbarkeit:** kostenlos, kein In-App-Kauf, kein Tip
      Jar. **Auch auf Macs mit Apple-Chip** anbieten: die App ist ein
      iPhone- und iPad-Ziel (`TARGETED_DEVICE_FAMILY = "1,2"`, kein Mac
      Catalyst) und läuft dort als iPad-App; CarPlay und Widget gibt es dort
      nicht. Am Mac von uns nicht gemessen; die App ist dort im Gebrauch.
- [ ] **App-Privacy-Angaben:** „Keine Daten erfasst“ wird vor der
      Einreichung je Datenfluss neu hergeleitet (Mär-Sync, Pocket-Casts-Import,
      Kataloge). MetricKit und alle Diagnose-Flaechen laufen nur in Builds aus
      Xcode, in keinem Release-Build (TestFlight, App Store).
- [ ] **Angabe zum Digital Services Act (Händler oder nicht):** Feld des
      Kontoinhabers.
- [ ] **Altersfreigabe, EULA, Zusatzbedingungen, Export:** Rechtsfrage vor
      der Einreichung (`docs/EULA.md`).
- [ ] **Screenshots:** die Bilder in `screenshots/` passen nicht. iPhone
      hochkant 1206 × 2622 (6,3-Zoll-Klasse), Pflicht ist 6,9 Zoll
      (1320 × 2868 oder 1290 × 2796); iPad 1488 × 2266, für 13 Zoll braucht
      es 2064 × 2752. Neue Bilder aus den Journeys am Simulator.
- [ ] **Beschreibung, Untertitel, Schlagworte, Support- und
      Marketing-URL, „Was ist neu“:** aus dem Entwurf der Store-Texte. Ein
      Server ist nicht nötig: Podcasts, Radio, die freien Kataloge und lokale
      Dateien gehen ohne Konto.

## Review-Notes (Textbaustein)

> Mär is a client for self-hosted audio: audiobooks (Audiobookshelf),
> podcasts (plain RSS, gpodder sync), music (Subsonic/OpenSubsonic such as
> Navidrome, and Jellyfin) and internet radio. **A server is NOT required to
> try the app**: podcasts, internet radio, the free catalogues (LibriVox,
> Internet Archive, Project Gutenberg, Jamendo) and imported local files all
> work without any account. Choose "Start without a server" on the setup
> screen.
>
> To review the Audiobookshelf part, please use the demo server credentials
> given in the review information fields above: enter the server address and
> the token on the setup screen (choose "API Token" as the sign-in method).
>
> No account creation, no payments, no tracking, no user data collection.
>
> App Transport Security: the app declares NSAllowsArbitraryLoads because it
> connects to self-hosted servers at addresses the user types in, commonly on
> a home network or a private mesh without a TLS certificate; fixed exception
> domains cannot name a user-entered address. Traffic to the Mär sync service
> is sealed inside an encrypted session on top of the connection, and podcast
> feed and artwork requests are still raised to https by the app.

Gemessen am Kandidaten: „Start without a server“ und „API Token“ sind die
Beschriftungen in `SetupView.swift`. Der Demo-Server antwortet (HTTP 200,
19.10.2026); ob sein Bestand für die Prüfung trägt, wird vor der Einreichung
geprüft.

## CarPlay

- [x] Die Berechtigung `com.apple.developer.carplay-audio` steht in
      `Maer.entitlements` für `fm.maer.app`, und die TestFlight-Builds sind
      damit signiert. Es gibt eine Entitlements-Datei für Simulator und Gerät.

## Upload und Abgabe

- [ ] Xcode: Ziel „Any iOS Device“, **Product → Archive**, Organizer,
      **Distribute App**, App Store Connect.
- [ ] TestFlight-Runde auf dem eigenen Gerät mit dem Store-Binary (Widget,
      Siri, CarPlay, Mac).
- [ ] Einreichen; bei Ablehnung sachlich antworten und den Demo-Zugang
      erneut nennen: bei Apps, die einen Server brauchen, ist der fehlende
      Zugang der häufigste Ablehnungsgrund.
