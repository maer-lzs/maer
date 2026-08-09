# App-Store-Checkliste für Mär

Stand: Juli 2026. Code-seitig ist die App einreichungsbereit (Privacy-Manifest,
Lokalisierung EN/DE) — die folgenden Schritte sind
Konto-/Portal-Arbeit.

## Voraussetzungen

- [ ] **Apple Developer Program** (99 €/Jahr) — ohne geht kein App Store.
- [ ] **Bundle-IDs registrieren** (developer.apple.com → Identifiers):
      `de.lzs.ABSPlayer` (App) und `de.lzs.ABSPlayer.MaerWidgets`
      (Widget), inkl. Capabilities: App Groups (`group.de.lzs.ABSPlayer`),
      falls abgefragt.
- [ ] In Xcode vom Personal Team aufs bezahlte Team wechseln (beide Targets),
      einmal auf Gerät bauen (Profile regenerieren sich).

## In der Codebasis (einmalig vor dem Upload)

- [ ] **Demo-Zugang in die PRÜFHINWEISE** (nicht in die App): In App Store
      Connect trägt man Serveradresse und Token in die Felder der
      App-Review-Informationen ein — „Anmeldedaten erforderlich" ankreuzen,
      dann „Benutzername"/„Passwort" bzw. das Feld „Hinweise". Der Prüfer
      trägt beides im Einrichtungsbildschirm ein.
      **Der frühere Knopf „Use Demo Server" ist zurückgebaut** (afd452a): er
      stand JEDEM Nutzer offen und streamte von the owner's Hausleitung, und
      sein Token stand im Klartext in einer Quelldatei — also im öffentlichen
      Spiegel. Zugangsdaten gehören in die Prüfhinweise, nicht in die App.
- [ ] **App-Icon** prüfen: `Assets.xcassets/AppIcon` — alle Größen belegt?
- [ ] `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` prüfen (aktuell 1.0/1).

## App Store Connect

- [ ] App anlegen: Name **„Mär"** (prüfen, ob frei; sonst z. B.
      „Mär – Hörbuch-Player"), Primärsprache Deutsch, Kategorie **Bücher**.
- [ ] **App-Privacy-Angaben**: „Keine Daten erfasst" — deckt sich mit
      `Sources/PrivacyInfo.xcprivacy` (keine Tracking-/Analytics-SDKs;
      Server-URL + Token bleiben im Keychain des Geräts).
- [ ] **Screenshots**: 6,9"-iPhone (Pflicht) und 13"-iPad — die Bilder in
      `screenshots/` haben passende Auflösungen (1290×2796 / 2064×2752-Klasse
      prüfen), ggf. frisch vom Simulator ziehen.
- [ ] **Beschreibung**: Kernaussage „Schlanker Player für selbst gehostete
      Audiobookshelf-Server — verlässlicher Fortschritts-Sync, offline,
      CarPlay, Siri". Klarstellen, dass ein EIGENER Audiobookshelf-Server
      nötig ist (Review + Nutzererwartung).

## Review-Notes (Textbaustein)

> Mär is a client for self-hosted audio: audiobooks (Audiobookshelf),
> podcasts (plain RSS), music (Subsonic/OpenSubsonic, Jellyfin) and internet
> radio. **A server is NOT required to try the app** — podcasts, internet
> radio, the free catalogues (LibriVox, Internet Archive, Project Gutenberg,
> Jamendo) and imported local files all work without any account. Choose
> "Start without a server" on the setup screen.
>
> To review the Audiobookshelf part, please use the demo server credentials
> given in the review information fields above: enter the server address and
> the token on the setup screen (choose "Token" as the sign-in method).
>
> No account creation, no payments, no tracking, no user data collection.

## CarPlay (separat, blockiert die Einreichung NICHT)

- [ ] Entitlement beantragen: developer.apple.com/contact/carplay
      (Kategorie Audio, Beschreibung „audiobook player for self-hosted
      Audiobookshelf servers"). Wartezeit oft Wochen.
- [ ] Nach Freigabe: Entitlement im Portal der Bundle-ID zuweisen, in Xcode
      `CODE_SIGN_ENTITLEMENTS` der App auf eine Datei MIT
      `com.apple.developer.carplay-audio` stellen (bisher nur in der
      Simulator-Variante `ABSPlayer-CarPlay.entitlements`), neues Binary
      hochladen. Bis dahin einfach ohne CarPlay einreichen.

## Upload & Abgabe

- [ ] Xcode: Gerät „Any iOS Device" → **Product → Archive** → Organizer →
      **Distribute App** → App Store Connect.
- [ ] TestFlight-Runde auf dem eigenen Gerät (installiert das Store-Binary,
      prüft Push-freie Funktionen, Widget, Siri).
- [ ] Einreichen; bei Ablehnung: Review-Antworten sachlich, Demo-Zugangsdaten
      erneut hervorheben — das ist bei Server-Client-Apps der häufigste
      Ablehnungsgrund.
