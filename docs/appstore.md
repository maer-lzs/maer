# App-Store-Checkliste für Mär

Stand: 3.5 (Build 56) am 26.10.2026 eingereicht und seit 29.10.2026 im
Store; 3.5.1 (Build 58) am 29.10.2026 eingereicht und seit 29.10.2026,
22:22 UTC, im Store (öffentliche Suche von Apple, App-ID `6799687154`,
gemessen 31.10.2026). Die Zeilen unter „Im Code“ sind am Kandidaten 3.5
(Build 55) gemessen, 19.10.2026, und für 56 nicht neu gemessen. Jede Zeile
nennt, woran sie gemessen ist; was nicht im Repository steht, nennt, wer es
klärt.

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

- [x] **Version** (Momentaufnahme des Kandidaten 3.5, Build 55):
      `MARKETING_VERSION = 3.5`, `CURRENT_PROJECT_VERSION = 55` an allen
      acht Stellen. Den laufenden Stempel misst diese Liste nicht; ihn hält
      `ReadmeVersionFenceTests.everyNamedVersionIsTheStamp` (ein Stempel im
      Projekt, gleich der neuesten Überschrift des Changelogs).
- [x] **App-Icon:** `Assets.xcassets/AppIcon.appiconset` trägt eine Grafik
      1024 × 1024 ohne Alphakanal, dazu die dunkle und die getönte Fassung
      (beide aus derselben dunklen Datei).
- [x] **Kategorie:** `LSApplicationCategoryType` ist
      `public.app-category.music` an beiden Stellen (Debug und Release),
      gleich der ersten Kategorie im Store; seit 31.10.2026, vorher
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

- [x] **App angelegt:** Name „Mär“, Sprachen Deutsch und Englisch.
      Kategorie Musik, sekundär Bücher, so eingereicht; der öffentliche
      Eintrag zeigt beide in dieser Reihenfolge (gemessen 31.10.2026).
- [x] **Preis und Verfügbarkeit:** kostenlos (Preis 0, gemessen), kein
      In-App-Kauf, kein Tip Jar; alle Länder außer China (Festland). **Auch
      auf Macs mit Apple-Chip:** die App ist ein iPhone- und iPad-Ziel
      (`TARGETED_DEVICE_FAMILY = "1,2"`, kein Mac Catalyst) und läuft dort
      als iPad-App; CarPlay und Widget gibt es dort nicht. Am Mac von uns
      nicht gemessen; die App ist dort im Gebrauch. Vision Pro aus.
- [x] **App-Privacy-Angaben:** „Keine Daten erfasst“ (Data Not Collected),
      so eingereicht. MetricKit und alle Diagnose-Flächen laufen nur in
      Builds aus Xcode, in keinem Release-Build (TestFlight, App Store).
- [x] **Angabe zum Digital Services Act:** kein Händler, so eingereicht.
- [ ] **Altersfreigabe, EULA, Zusatzbedingungen, Export:** im Store steht
      12+ (gemessen 31.10.2026). EULA und Zusatzbedingungen
      (`docs/EULA.md`) und die Export-Kennzeichnung oben sind ohne
      rechtliche Prüfung eingereicht; was in App Store Connect dazu steht,
      steht nicht im Repository.
- [x] **Screenshots:** aus Simulatoren mit dem Release-Build 56, vom
      Kontoinhaber aufgenommen, keine umgerechneten Bilder. Pflichtklassen
      laut App Store Connect: iPhone „medium display“ (1206 × 2622 oder
      1179 × 2556) und iPad 13 Zoll (2064 × 2752); Duo freiwillig. Im
      öffentlichen Eintrag stehen fünf iPhone- und fünf iPad-Bilder
      (gemessen 31.10.2026). Die Store-Bilder liegen nicht im Repository;
      `screenshots/` trägt die verkleinerten Bilder der READMEs.
- [x] **Beschreibung, Werbetext, Untertitel, Schlagworte, „Was ist
      neu“:** Deutsch und Englisch eingereicht, für 3.5.1 mit eigenen
      Neuerungen und Schlagworten; die Texte stehen nicht im Repository.

## Review-Notes (so eingereicht)

Der Text, mit dem 3.5 eingereicht wurde. Benutzername und Passwort des
Demo-Zugangs stehen nur in den Anmeldefeldern von App Store Connect; der Text
hier lässt den Benutzernamen weg.

> Mär is an audio player for people who run their own media servers:
> audiobooks (Audiobookshelf), podcasts (RSS, with optional gpodder sync),
> music (Subsonic/OpenSubsonic servers such as Navidrome, and Jellyfin) and
> internet radio.
>
> TRYING THE APP WITHOUT A SERVER
> No server and no account are needed. On the setup screen choose "Start
> without a server". Podcasts, internet radio, the open catalogues (LibriVox,
> Internet Archive, Project Gutenberg, Jamendo) and imported audio files then
> work right away.
>
> TRYING THE AUDIOBOOKSHELF PART
> We run a demo server for the review. Username and password are in the
> sign-in fields above.
> 1. On the setup screen enter the server address: https://demo.maer.fm
> 2. Leave the sign-in method on "Password" and enter the username and the
>    password.
> 3. The Audiobooks tab then shows the demo library.
>
> CONTENT
> The app hosts no content. Everything it plays comes from the user's own
> servers, from public podcast feeds and radio streams, or from open
> catalogues of public domain and openly licensed works.
>
> PRIVACY
> No account creation, no payments, no ads, no tracking, and no collection of
> user data. Listening positions can sync through the user's own iCloud
> account or through a sync service the user hosts.
>
> PERMISSIONS
> Background audio is used to keep playback running with the screen locked
> and in CarPlay. Local network access is used only to reach the user's own
> servers at home.
>
> APP TRANSPORT SECURITY
> The app declares NSAllowsArbitraryLoads because it connects to servers the
> user runs and enters by address. Users typically reach them by a full host
> name on a home network or through a private VPN, often without a TLS
> certificate. NSAllowsLocalNetworking covers only .local and unqualified
> names, and fixed exception domains cannot name an address the user types
> in. Where the app itself chooses the address it stays on https: podcast
> feeds and artwork are requested over https even when a feed names http.
> Traffic to the Mär sync service is additionally sealed in an encrypted
> session on top of the connection.

Gemessen am eingereichten Build 56 (`c993ee4c`): „Start without a server“
und „Password“ sind Beschriftungen in `SetupView.swift`, und die Anmeldung
steht dort von Anfang an auf Passwort (`loginMode = .password` in
`AuthViewModel.swift`). Der Demo-Server antwortet (HTTP 200, 31.10.2026).

## CarPlay

- [x] Die Berechtigung `com.apple.developer.carplay-audio` steht in
      `Maer.entitlements` für `fm.maer.app`, und die TestFlight-Builds sind
      damit signiert. Es gibt eine Entitlements-Datei für Simulator und Gerät.

## Upload und Abgabe

- [x] Xcode: Ziel „Any iOS Device“, **Product → Archive**, Organizer,
      **Distribute App**, App Store Connect (3.5 (56) am 26.10.2026, 3.5.1
      (58) am 29.10.2026, beide vom Kontoinhaber).
- [x] TestFlight-Runde auf dem eigenen Gerät mit Build 56 vor der
      Einreichung (Mini-Leiste beim Titelwechsel, Widget).
- [x] Eingereicht und freigegeben: 3.5 im Store seit 29.10.2026, 3.5.1 seit
      29.10.2026. Bei einer Ablehnung sachlich antworten und den Demo-Zugang
      erneut nennen: bei Apps, die einen Server brauchen, ist der fehlende
      Zugang der häufigste Ablehnungsgrund.
- [ ] Jede neue Version braucht eine neue Versionsnummer: nach der
      Freigabe nimmt App Store Connect unter derselben Nummer keinen Build
      mehr an.
