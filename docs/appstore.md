# App-Store-Checkliste für Mär

Stand: Juli 2026. Code-seitig ist die App einreichungsbereit (Privacy-Manifest,
Demo-Zugang-Mechanik, Lokalisierung EN/DE) — die folgenden Schritte sind
Konto-/Portal-Arbeit.

## Voraussetzungen

- [ ] **Apple Developer Program** (99 €/Jahr) — ohne geht kein App Store.
- [ ] **Bundle-IDs registrieren** (developer.apple.com → Identifiers):
      `de.lzs.ABSPlayer` (App) und `de.lzs.ABSPlayer.HoerregalWidgets`
      (Widget), inkl. Capabilities: App Groups (`group.de.lzs.ABSPlayer`),
      falls abgefragt.
- [ ] In Xcode vom Personal Team aufs bezahlte Team wechseln (beide Targets),
      einmal auf Gerät bauen (Profile regenerieren sich).

## In der Codebasis (einmalig vor dem Upload)

- [ ] **Demo-Zugang füllen**: `Sources/Views/SetupView.swift` → `DemoAccess`
      (`serverURL` + `apiToken` eines öffentlich erreichbaren Demo-Servers
      mit 2–3 gemeinfreien Hörbüchern). Apple LEHNT Server-gebundene Apps
      ohne testbaren Zugang regelmäßig ab.
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

> Mär is a client for the self-hosted, open-source audiobook server
> Audiobookshelf (audiobookshelf.org). A server is required. For review,
> please use the built-in demo access: on the setup screen tap
> "Use Demo Server" — it connects to our demo instance with public-domain
> audiobooks. No account creation, no payments, no user data collection.

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
      prüft Push-freie Funktionen, Widget, Live Activity, Siri).
- [ ] Einreichen; bei Ablehnung: Review-Antworten sachlich, Demo-Zugang
      erneut hervorheben — das ist bei Server-Client-Apps der häufigste
      Ablehnungsgrund.
