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
- [ ] **App Transport Security, Begründung für den Review:** `Maer-Info.plist`
      trägt `NSAllowsArbitraryLoads = true` und KEINEN feineren Schlüssel
      daneben (Apple ignoriert den globalen, sobald `…ForMedia`,
      `…InWebContent` oder `NSAllowsLocalNetworking` mit im Wörterbuch
      steht; gemessen 19.09.2026). Grund, den der Prüfer liest: Mär spricht
      mit selbst gehosteten Servern unter Adressen, die die Person selbst
      eingibt, oft im Heimnetz oder in einem Mesh (`100.64.0.0/10`) ohne
      Zertifikat; feste Ausnahme-Domains können eine eingegebene Adresse nicht
      nennen; der Verkehr zum Mär-Sync-Dienst reist versiegelt in einer
      Sitzung, Feeds und Cover hebt die App weiterhin selbst auf https.
      Der Zaun `TransportSecurityFenceTests` hält den Schlüssel genau so.
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
>
> App Transport Security: the app declares NSAllowsArbitraryLoads because it
> connects to self-hosted servers at addresses the user types in, commonly on
> a home network or a private mesh without a TLS certificate; fixed exception
> domains cannot name a user-entered address. Traffic to the Mär sync service
> is sealed inside an encrypted session on top of the connection, and podcast
> feed and artwork requests are still raised to https by the app.

## CarPlay (separat, blockiert die Einreichung NICHT)

**Stand:** Das Entitlement ist am 26.07. erteilt — **für die App-ID
`de.lzs.ABSPlayer`**. Es gibt nur noch EINE Entitlements-Datei
(`Maer.entitlements`), die Simulator-Sonderdatei ist entfernt; Simulator
und Gerät signieren gleich.

**Das ist noch nicht das Ende:** Mit dem Wechsel auf die Kennung
`fm.maer.app` (Auftrag `f52398e`/`03e5e0c`) entsteht eine NEUE App-ID, und die
braucht einen **eigenen Antrag**. Er ist gestellt, die Freigabe steht aus.

- [x] Entitlement für `de.lzs.ABSPlayer` beantragt und erteilt
- [ ] Entitlement für `fm.maer.app` — beantragt, **ausstehend**
- [ ] Erst NACH dieser Freigabe die Kennung umstellen. Andernfalls scheitert
      die Gerätesignatur am `com.apple.developer.carplay-audio`, und die am
      26.07. abgeschaffte Sonderbehandlung käme zurück.

## Upload & Abgabe

- [ ] Xcode: Gerät „Any iOS Device" → **Product → Archive** → Organizer →
      **Distribute App** → App Store Connect.
- [ ] TestFlight-Runde auf dem eigenen Gerät (installiert das Store-Binary,
      prüft Push-freie Funktionen, Widget, Siri).
- [ ] Einreichen; bei Ablehnung: Review-Antworten sachlich, Demo-Zugangsdaten
      erneut hervorheben — das ist bei Server-Client-Apps der häufigste
      Ablehnungsgrund.
