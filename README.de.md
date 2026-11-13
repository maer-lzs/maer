<p align="center">
  <img src="docs/logo.png" alt="Mär App-Icon" width="128" height="128">
</p>

# Mär

Ein schlanker, quelloffener iOS-/iPadOS-Client für **selbst gehostetes Audio**: Hörbücher, Podcasts, Musik und Internetradio in einer App, mit einer Designsprache und einem Player.

Mär ist **server-first und offline-first**: Bibliothek, Metadaten, Cover und Fortschritt liegen auf deinen eigenen Servern und erreichen die App über **offene Standard-APIs ohne clientseitige API-Keys**: [Audiobookshelf](https://www.audiobookshelf.org/), Subsonic/OpenSubsonic, Jellyfin, gpodder/mygpo, klassisches RSS (einschließlich der Kanal-Feeds, die eine Pinchflat-Instanz spiegelt) und den offenen Radio-Browser-Katalog. Sein Fundament ist **verlässlicher Fortschritts-Sync** über mehrere Geräte hinweg, ohne dass ein Buch versehentlich auf 0 zurückgesetzt wird, auch komplett offline.

> „Mär“ ist ein altes deutsches Wort für Erzählung oder Geschichte, passend für einen Audio-Player. Das Xcode-Projekt ist `Maer.xcodeproj`; „Mär“ mit Umlaut ist der Anzeigename.

Entstanden als privater Ersatz für einen Client, der beim Gerätewechsel regelmäßig den Hörfortschritt verlor. Inzwischen ist daraus ein universeller Client für das selbst gehostete, quelloffene Audio-Ökosystem geworden, auf einer Provider-Architektur, dabei bewusst fokussiert: kein Multi-User, keine Server-Verwaltung, nur hören und den Stand verlässlich synchron halten, online wie offline.

> **Hinweis:** Dies ist ein privates Hobby-Projekt ohne Gewähr. Es ist nicht mit dem Audiobookshelf-Projekt verbunden.

**Zuhause:** <https://maer.fm> · **Quelltext:** <https://github.com/maer-lzs/maer> · **Gemeinschaft:** <https://www.reddit.com/r/maer_fm/>

## Screenshots

Version 3.5 (56) im Simulator, an echten Quellen (eine Audiobookshelf- und eine gonic-Testinstanz, öffentliche Podcast-Feeds und Radiosender), deutsche Oberfläche.

| Start | Podcasts | Podcastseite | Album | Suche |
|---|---|---|---|---|
| ![Start](screenshots/iphone_home.jpg) | ![Podcasts](screenshots/iphone_podcasts.jpg) | ![Podcastseite](screenshots/iphone_podcast_page.jpg) | ![Album](screenshots/iphone_album.jpg) | ![Suche](screenshots/iphone_search.jpg) |

| Start (iPad) | Podcasts (iPad) | Musik (iPad) |
|---|---|---|
| ![Start auf dem iPad](screenshots/ipad_home.jpg) | ![Podcasts auf dem iPad](screenshots/ipad_podcasts.jpg) | ![Musik auf dem iPad](screenshots/ipad_music.jpg) |

| Playlist (iPad) | Player (iPad) | Radio (iPad) |
|---|---|---|
| ![Playlist auf dem iPad](screenshots/ipad_playlist.jpg) | ![Player auf dem iPad](screenshots/ipad_player.jpg) | ![Radio auf dem iPad](screenshots/ipad_radio.jpg) |

| Start (iPhone Duo, aufgeklappt) | Podcasts (iPhone Duo, aufgeklappt) |
|---|---|
| ![Start auf dem aufgeklappten iPhone Duo](screenshots/duo_open_home.jpg) | ![Podcasts auf dem aufgeklappten iPhone Duo](screenshots/duo_open_podcasts.jpg) |

| Podcastseite (iPhone Duo, aufgeklappt) | Playlist (iPhone Duo, aufgeklappt) |
|---|---|
| ![Podcastseite auf dem aufgeklappten iPhone Duo](screenshots/duo_open_podcast_page.jpg) | ![Playlist auf dem aufgeklappten iPhone Duo](screenshots/duo_open_playlist.jpg) |

| Hörbücher (iPhone Duo, zugeklappt) | Radio (iPhone Duo, zugeklappt) |
|---|---|
| ![Hörbücher auf dem zugeklappten iPhone Duo](screenshots/duo_folded_audiobooks.jpg) | ![Radio auf dem zugeklappten iPhone Duo](screenshots/duo_folded_radio.jpg) |

## Funktionen

Eine App, ein Player und eine Gestaltung für vier Arten von Audio. Jede Funktion im Einzelnen: [docs/features.de.md](docs/features.de.md).

### Hörbücher

- Audiobookshelf-Bibliotheken als anpassbares Cover-Raster, mit Serien, Autoren, Filtern und Sortierung, die bleiben, wie du sie verlassen hast
- Bücher aus mehreren Dateien spielen als eines, mit Kapiteln, Lesezeichen und Schlaftimer
- Ganze Bücher zum Hören ohne Netz laden; die Bibliothek bleibt nutzbar, wenn der Server nicht erreichbar ist
- Freie Hörbücher von LibriVox, Project Gutenberg und dem Internet Archive, ohne Server
- Hörbuch-Bibliotheken aus Booksonic und Jellyfin im selben Reiter

### Podcasts

- Abos über RSS, Podcast-Bibliotheken von Audiobookshelf oder einen gpodder-Server, abgeglichen in einer Liste
- Import aus Apple Podcasts, Overcast, AntennaPod, Pocket Casts und OPML, mit deinen Hörständen; Export ebenso
- Als Nächstes, Routinen, Einstellungen je Sendung, Mitteilungen bei neuen Folgen, Kapitel, Transkripte und Premium-Feeds
- Empfehlungen aus deiner eigenen Bibliothek und Hörzeit

### Musik

- Subsonic- und OpenSubsonic-Server (Navidrome, gonic, Airsonic) und Jellyfin, nebeneinander
- Playlisten zum Anlegen und Bearbeiten, Künstlerseiten, Alben zum Laden, Favoriten und Scrobbeln
- Liedtexte im Player, vom Server oder von LRCLIB
- Freie Musik von Jamendo und den Netlabels des Internet Archive

### Radio

- Der offene Katalog von Radio Browser und deine eigenen Stream-Adressen
- Sender deines Landes und deiner Region, Favoriten und zuletzt gehörte Sender, die zwischen deinen Geräten reisen
- Das laufende Lied aus dem Stream, im Player und auf dem Sperrbildschirm

### Überall

- Eine Suche über alle Quellen, ein Start-Reiter über alle Medien und Mär-Playlisten über Quellen hinweg
- Ein Fortschritt, der nie an den Anfang springt, zwischen Geräten und ohne Netz
- CarPlay, Widgets, Siri und Kurzbefehle, Sperrbildschirm und Dynamic Island
- Eine Sendung, Folge, einen Sender, ein freies Hörbuch oder einen Titel von Jamendo als Link teilen
- iPhone, iPad und das iPhone Duo, Dynamic Type und VoiceOver

## Kompatibel mit

Mär spricht mit Servern über ihre Standard-Schnittstellen:

- **Audiobookshelf** für Hörbücher und Podcasts
- **Navidrome**, **gonic** und andere Subsonic- oder OpenSubsonic-Server sowie **Jellyfin** für Musik (Jellyfin auch für Hörbücher)
- **oPodSync** und andere gpodder-Server für Podcast-Abos
- Kanal-Feeds aus **Pinchflat**, jeder **RSS**-Feed, das Verzeichnis **PodcastIndex** und der Katalog von **Radio Browser**

Welche Server aus der App geprüft sind und welche nur über eine Protokoll-Probe: [docs/features.de.md](docs/features.de.md#kompatibel-mit).

## Privatsphäre & Datensicherheit

Mär hat kein Konto, keinen eigenen Dienst, kein Tracking und keinen fremden Code. Deine Bibliothek, Hörstände und Anmeldungen bleiben auf deinem Gerät und deinen eigenen Servern. Hörstände, Wahlen und Playlisten reisen zwischen deinen Geräten über iCloud, das du abschalten kannst, oder über einen Mär-Sync-Dienst, den du selbst betreibst. Jeder fremde Dienst, der nicht dein eigener Server ist, hat in den Einstellungen einen eigenen Schalter.

Die Datenschutzerklärung: [maer.fm/datenschutz](https://maer.fm/datenschutz). Was das Gerät verlässt, Aussage für Aussage: [docs/privacy.de.md](docs/privacy.de.md).

## Voraussetzungen

- Xcode mit einem iOS-26-SDK oder neuer (nötig zum Bauen der App, die Apples Liquid-Glass-API nutzt, wo das System sie hat)
- Deployment-Ziel **iOS/iPadOS 18.0** (Mindest-Laufzeitversion); auf iOS 18 bis 25 fallen die Glas-Flächen auf das System-Material zurück
- Eine Audioquelle, aber **zum Start ist kein Server nötig**:
  - du kannst **ohne jeden Server beginnen** und Radio, Podcasts (RSS), die offenen Kataloge und importierte lokale Dateien sofort nutzen
  - **Audiobookshelf** für Hörbücher und Podcasts, mit deinen Kontodaten oder einem API-Token
  - und/oder ein **Subsonic/OpenSubsonic**-kompatibler Musikserver (Navidrome, gonic, Airsonic) für den Musik-Tab
  - **Internetradio** braucht keinen Server: der öffentliche Radio-Browser-Katalog, plus beliebige eigene Stream-URLs
  - Podcast-Abos können zusätzlich über einen selbst gehosteten **gpodder/oPodSync**-Server abgeglichen werden (optional; iCloud, ein Mär-Sync-Dienst und Audiobookshelf sind die anderen Backends)
  - optional ein **Mär-Sync-Dienst**, den du selbst betreibst ([maer-sync](https://github.com/maer-lzs/maer-sync), eine SQLite-Datei, nur hinter TLS auf deinem eigenen Host; der ausgerollte Build ist eine einzelne statisch gelinkte Rust-Datei, die Python-Umsetzung desselben Vertrags bleibt daneben im Baum), damit Stände, Statistik, Playlisten und Wahlen ohne iCloud zwischen deinen Geräten reisen
- Eine Apple-ID zum Signieren; mit einer kostenlosen Apple-ID vorher die Fähigkeiten entfernen, die ein kostenloses Team nicht signieren kann (siehe Schritt 2 unten)

## Bauen & installieren

Das Repository enthält das komplette Xcode-Projekt; nichts muss zusammengebaut werden.
**Mär baut ohne jeden API-Schlüssel** (zwei optionale App-Schlüssel für Jamendo und
PodcastIndex werden aus `Config/AppKeys.local.xcconfig` gelesen, wenn es die Datei gibt;
ein Schlüssel, der in den Einstellungen der App eingetragen ist, geht vor. Ohne jeden
Schlüssel bleiben die Jamendo-Reihen weg, und die Podcast-Suche nimmt Apples Verzeichnis)
und hat **keine Abhängigkeiten von Dritten**: kein Paketmanager-Schritt, nichts aufzulösen.

1. Repo klonen und **`Maer.xcodeproj`** öffnen (Xcode mit einem iOS-26-SDK oder neuer).
2. **Signieren** (Ziel `Maer` → Signing & Capabilities):
   - **Team:** deine Apple-ID. `Maer.entitlements` verlangt CarPlay-Audio, Push-Benachrichtigungen, iCloud (CloudKit-Container und Schlüsselwert-Speicher), Associated Domains (`applinks:maer.fm`, damit geteilte Links in der App öffnen) und eine App Group. Ein kostenloses Team kann CarPlay, Push, iCloud und Associated Domains nicht signieren: mit einer kostenlosen Apple-ID zuerst diese vier Fähigkeiten entfernen. Die App gleicht dann nichts über iCloud ab, und geteilte Links öffnen im Browser.
   - **Associated Domains** (bezahltes Team): maer.fm nennt nur die App dieses Projekts, also im eigenen Bau die Fähigkeit entfernen oder auf eine eigene Domain zeigen lassen, die `site/.well-known/apple-app-site-association` mit deiner App-ID ausliefert.
   - **Bundle Identifier:** auf etwas Eindeutiges ändern, z. B. `de.deinname.maer`, auf BEIDEN Zielen (`Maer` und `MaerWidgetsExtension`; die Widget-ID muss ein Kind der App-ID bleiben, z. B. `de.deinname.maer.widgets`)
   - In `Sources/Networking/KeychainStore.swift` die Konstante `service` auf denselben Bundle Identifier setzen.
   - **App Group:** die Gruppen-Kennung in den `.entitlements`-Dateien beider Ziele und in `Sources/Models/WidgetShared.swift` durch eine eigene ersetzen (z. B. `group.de.deinname.maer`); eine Gruppe, die auf das Team eines anderen registriert ist, signiert nicht.
   - **iCloud-Container** (nur mit bezahltem Team): `iCloud.fm.maer.app` in `Maer.entitlements` und in `Sources/Networking/CloudZoneDatabase.swift` durch einen eigenen Container ersetzen.
3. iPhone anschließen, als Ziel wählen (Hintergrund-Audio lässt sich auf einem echten Gerät weit verlässlicher testen als im Simulator), ▶ drücken.
4. Auf dem iPhone die Apple-ID bei Nachfrage einmal unter **Einstellungen → Allgemein → VPN & Geräteverwaltung** vertrauen.

Hintergrund-Audio, das Widget-Ziel, die CarPlay-Szene und iPhone/iPad sind im Projekt schon eingerichtet.

**Kostenlose Apple-ID ohne Developer Program:** mit den vier entfernten Fähigkeiten läuft die App 7 Tage pro Installation, danach einmal über Xcode neu bauen. **CarPlay** braucht Apples CarPlay-Audio-Berechtigung (developer.apple.com/contact/carplay, bezahltes Konto), um die Fähigkeit für ein Gerät zu signieren und sie im echten Auto zu nutzen. Mit Xcode 27 zeigt sich CarPlay nur mit einem iPhone am Kabel, nicht mit einem Simulator.

## In der App anmelden

- Server: `dein-server.example.com`; `https://` wird automatisch ergänzt
- Dann entweder Benutzername und Passwort, ein API-Token oder die Schaltfläche für die Einmalanmeldung, wenn dein Server sie anbietet

Wo du ein Token findest und wie die Anmeldung deine Sitzung hält: [docs/sync-and-sign-in.de.md](docs/sync-and-sign-in.de.md#anmelde-optionen).

## Weitere Dokumentation

- [Funktionen im Einzelnen](docs/features.de.md), mit der Liste der Server und der iPad-Unterstützung
- [Privatsphäre und Datensicherheit](docs/privacy.de.md)
- [Abgleich und Anmeldung](docs/sync-and-sign-in.de.md)
- [Aufbau der Quellen](docs/architecture.de.md)
- [Endpunkte](docs/endpoints.de.md)
- [Changelog](CHANGELOG.md)

## Lizenz

GPL-3.0-or-later, siehe [LICENSE](LICENSE). Bis v2.1 wurde Mär unter der
MIT-Lizenz angeboten; ab diesem Commit gilt GPL-3.0-or-later. LICENSE-Dateien
in der älteren Historie sind historische Artefakte.

Mär steht unter der GPL-3.0-or-later. Zusätzlich gelten Bedingungen nach
GPL-3.0 Abschnitt 7: eine zusätzliche Erlaubnis für die Verteilung über
App-Vertriebskanäle und ein Vorbehalt an Name und Symbol: siehe
[LICENSE-ADDITIONAL-TERMS](LICENSE-ADDITIONAL-TERMS). Für die Verteilung über
den App Store gilt eine eigene Endnutzer-Vereinbarung anstelle der von Apple:
[docs/EULA.md](docs/EULA.md). Der Quelltext jeder veröffentlichten Fassung
bleibt unter <https://github.com/maer-lzs/maer> verfügbar.

## Über dieses Projekt

Mär ist mit Unterstützung von KI entstanden: Anthropic Claude (Opus, Sonnet und Fable), Mistral (Codestral und Mistral Large, über Mistrals API) für Gegenprüfungen, dazu lokal betriebene Modelle mit offenen Gewichten (qwen3, devstral und OpenAIs offene gpt-oss-Gewichte) über Ollama für Werkzeuge.
