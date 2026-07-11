# Mär

Ein schlanker, quelloffener iOS-/iPad-Client für [Audiobookshelf](https://www.audiobookshelf.org/).
Fokus auf genau eine Sache: **verlässlicher Fortschritts-Sync** über mehrere
Geräte hinweg, ohne dass ein Buch versehentlich auf 0 zurückgesetzt wird —
auch komplett offline.

> „Mär" ist ein altes Wort für Erzählung oder Geschichte — passend für einen
> Hörbuch-Player. (Das Xcode-Projekt heißt intern weiterhin `ABSPlayer`;
> „Mär" ist nur der Anzeigename.)

Entstanden als privater Ersatz für einen Client, der beim Geräte-Wechsel
regelmäßig den Hörfortschritt verlor. Die App ist bewusst minimal gehalten:
kein Multi-User, keine Podcasts, keine Server-Verwaltung — nur Hörbücher hören
und den Stand sauber synchronisieren, online wie offline.

> **Hinweis:** Dies ist ein privates Hobby-Projekt ohne Gewähr. Es ist nicht
> mit dem Audiobookshelf-Projekt affiliiert.

## Screenshots

| Bibliothek | Player | Buchseite |
|---|---|---|
| ![Bibliothek](screenshots/iphone_library.png) | ![Player](screenshots/iphone_player.png) | ![Buchseite](screenshots/iphone_detail.png) |

| Bibliothek (iPad) | Buchseite (iPad) |
|---|---|
| ![Bibliothek auf dem iPad](screenshots/ipad_library.png) | ![Buchseite auf dem iPad](screenshots/ipad_detail.png) |

| Bibliothek (quer) | Buchseite (quer) |
|---|---|
| ![Bibliothek im Querformat](screenshots/iphone_library_landscape.png) | ![Buchseite im Querformat](screenshots/iphone_detail_landscape.png) |

## Features

- Anmeldung per Benutzername/Passwort oder API-Token (kompatibel mit altem und neuem Auth-System)
- Bibliothek als adaptives Cover-Grid (iPhone & iPad), das sich selbst so
  berechnet, dass es immer exakt zur verfügbaren Bildschirmbreite passt —
  ohne Überlappung, auch nach einer Bildschirm-Drehung
- **Such-Overlay**: Der schwebende Glas-Such-Button öffnet ein vollflächiges
  Glas-Sheet über der Bibliothek (sie scheint leicht abgedunkelt durch) mit
  auto-fokussiertem Feld, Echtzeit-Filterung pro Tastendruck und
  Bereichs-Chips — Alle / Autor / Genre / Serie; Ergebnisse als Zeilen mit
  kleinen Cover-Thumbnails, Gruppen-Bereiche mit Drill-down direkt im
  Overlay, ein Buch-Tap schließt die Suche und öffnet die Detailseite
- Sortierung nach Titel, Autor, zuletzt hinzugefügt oder zuletzt gehört, mit
  auf-/absteigend umschaltbar; Sortierung und Filter werden über
  App-Neustarts hinweg gemerkt
- Filter (alle/unfertig/fertig)
- „Weiter hören"-, „Kürzlich hinzugefügt"- und „Heruntergeladen"-Sektionen
- Haptic-Touch-Kontextmenü auf Covern für Schnellaktionen: abspielen,
  herunterladen, als gehört markieren
- Fortschrittsbalken, „Abgeschlossen"-Häkchen und Download-Status-Abzeichen
  direkt auf jedem Cover; abgeschlossene Bücher werden leicht entsättigt
  dargestellt
- Buchdetailseite mit Beschreibung, Erzähler, Serie, Genre, Erscheinungsjahr
  und Gesamtdauer; Download und „Als gehört markieren" direkt von der
  Detailseite aus, mit einem Play/Pause-Button, der eine bereits laufende
  Session korrekt anzeigt und steuert
- Persistente, schwebende Mini-Player-Leiste im Look von Apples Liquid-Glass-
  Design (iOS 26, mit sicherem Material-Rückfallnetz auf älteren Versionen),
  mit kreisförmigem Fortschrittsring ums Cover; zusätzliche Transport-Buttons
  (Vor-/Zurückspulen, AirPlay) erscheinen nur auf dem iPad oder im
  Querformat, damit auf dem iPhone im Hochformat mehr Platz für den Titel
  bleibt; stellt die zuletzt gehörte Session auch nach einem kompletten
  App-Neustart automatisch wieder her (pausiert, spielt nie von selbst los)
- Voller Player als rundes Liquid-Glass-Sheet ÜBER der Bibliothek — nach
  unten ziehen (Griff oder Seitenzonen) minimiert zurück zum Mini-Player,
  die Bibliothek scheint beim Ziehen durchs Glas durch; großes Cover, aus
  dem Cover abgeleiteter Farbverlauf, Kapitelmarken direkt auf dem Scrubber,
  Play/Pause/Scrub, konfigurierbares Sprung-Intervall (15/30/60 s, gilt auch
  für Lockscreen- und Mini-Player-Buttons), Wiedergabegeschwindigkeit pro
  Buch gemerkt, Sleep-Timer (feste Minuten oder bis Kapitelende), AirPlay,
  „Als gehört markieren", dezentes haptisches Feedback; im Querformat
  (iPhone und iPad) wandert das Cover neben die Bedienelemente
- Transiente Glas-Pille für Sync-/Quell-Ereignisse („Serverstand
  übernommen", „Offline — wird nachgereicht", „Fortschritt gesichert",
  „Konflikt erkannt") über dem Mini-Player bzw. im vollen Player, blendet
  nach ein paar Sekunden von selbst aus
- Background Audio, Lockscreen- und Dynamic-Island-Anzeige inkl. Cover
- **Multi-Track-Wiedergabe**: Hörbücher, die aus mehreren Audiodateien
  bestehen (statt zu einer einzigen M4B zusammengefasst zu sein), spielen
  nahtlos nacheinander durch, mit korrekter Kapitel- und
  Fortschrittsberechnung über das ganze Buch hinweg
- **Offline-Download** pro Buch (manuell, mit WLAN-Warnung); lädt alle
  Tracks eines Buchs herunter, nicht nur den ersten, läuft auch im
  Hintergrund weiter, zeigt einen Live-Fortschrittsring auf dem
  Cover-Abzeichen und speichert Kapitel/Metadaten lokal mit — ein
  heruntergeladenes Buch öffnet und spielt komplett offline, ohne dass für
  die Kapitelliste noch eine Serveranfrage nötig wäre
- **Offline-Bibliothek**: Ist der Server nicht erreichbar, zeigt die
  Bibliothek die heruntergeladenen (tatsächlich abspielbaren) Bücher aus dem
  Festplatten-Cache; Cover heruntergeladener Bücher liegen persistent (von
  iOS-Cache-Aufräumläufen unberührt), Cover werden in gerätepassender
  Auflösung ohne Nachkomprimierung gespeichert
- **Offline-Sync-Warteschlange**: Ein Fortschritts-Update, das nicht
  gesendet werden kann — offline oder wegen eines Serverfehlers —, wird
  atomar auf der Festplatte zwischengespeichert und beim nächsten App-Start
  bzw. sobald wieder Verbindung besteht automatisch nachgereicht; vor dem
  Nachreichen wird mit dem Server abgeglichen, damit ein veralteter
  Warteschlangen-Stand nie einen neueren Stand eines anderen Geräts
  überschreibt
- Automatische Wiederverbindungs-Erkennung: Bibliothek und wartende
  Sync-Updates aktualisieren sich von selbst, sobald die Verbindung
  zurückkommt, ganz ohne die App in den Hintergrund schicken zu müssen
- **Sicherer Progress-Sync** (siehe unten) und Multi-Device-Abgleich
- **Lesezeichen** pro Buch (Position + Titel) über die Audiobookshelf-
  Bookmark-API, direkt aus dem Player, mit Offline-Warteschlange — offline
  angelegte/gelöschte Lesezeichen werden automatisch nachgereicht
- Einstellungen: Sprung-Intervall, Standard-Geschwindigkeit für neue Bücher,
  **Smart Rewind** (nach längerer Pause etwas früher wieder einsetzen),
  **automatisch das nächste ungehörte Serienbuch starten**, Darstellung
  (System/Hell/Dunkel), WLAN-Warnung abschaltbar, Speicherverwaltung,
  Sync-Status mit „Jetzt synchronisieren", Bibliotheks-Auswahl bei mehreren
  Libraries, App-Version
- **Siri & Kurzbefehle**: „Weiterhören in Mär" und „Spiele *Buch* in
  Mär" (Buchnamen kommen aus dem Offline-Bibliothekscache), plus
  Home-Screen-Schnellaktion für das zuletzt gehörte Buch
- **Live Activity / Dynamic Island** für den Schlaf-Timer: Läuft ein Timer,
  zeigt ein Mond-Countdown auf Sperrbildschirm und in der Dynamic Island
  (friert im „bis Kapitelende"-Modus bei Pause ein) — bewusst nicht mehr,
  Apples eigenes „Now Playing" deckt die Wiedergabe auf dem Sperrbildschirm
  bereits ab; Widget-Extension-Target einmalig anlegen, siehe
  `LiveActivityWidget/ANLEITUNG.md`
- **CarPlay**: drei Tabs (Weiter hören / Heruntergeladen / Bibliothek) mit
  Cover-Thumbnails und dem System-Now-Playing, teilt sich die Wiedergabe-
  Session mit dem Telefon — funktioniert auch beim Kaltstart im Auto
  (Offline-Cache als Rückfallebene); im Simulator sofort testbar, fürs
  echte Auto braucht es Apples CarPlay-Audio-Entitlement
  (developer.apple.com/contact/carplay)
- Adaptives Hell-/Dunkel-Design: das Liquid-Glass-Chrome (Mini-Player,
  Suche, Toolbar-Buttons) bekommt im hellen Modus einen pastelligen Hauch
  der aktuellen Cover-Farbe; beim Buchwechsel taucht der Mini-Player kurz
  ab und federt mit neuer Farbe zurück
- Performance: Grid-Zellen dekodieren ein kleines abgeleitetes Thumbnail
  statt des vollen Covers — flüssiges Scrollen und deutlich weniger
  Speicher bei großen Bibliotheken; die Bücherliste kommt im minified-
  Format vom Server
- Härtung: Speicherplatz-Check vor Downloads, Magic-Byte-Container-
  Erkennung mit automatischer Endungs-Reparatur (unit-getestet),
  automatische Erholung bei mitten in der Wiedergabe kaputten Tracks statt
  stiller Stille, VoiceOver-Labels auf allen Transport-Buttons

## Die Sync-Kernregel

Das Herzstück der App. Ein bewusst vom Nutzer ausgelöster Sprung (Scrubber,
Kapitel, ±30s, Lockscreen) gilt als gewollt und wird sofort synchronisiert —
auch nach hinten. Ein Warn-Dialog erscheint nur, wenn der Fortschritt **ohne
Nutzeraktion** um mehr als 120 Sekunden absackt (z. B. ein fehlerhafter
Client-Reset). Bei „Abbrechen" springt die Wiedergabe zurück zum zuletzt
gespeicherten Stand.

Beim Geräte-Wechsel gleicht die App vor jedem Play kurz mit dem Server ab.
Es gewinnt der Eintrag mit dem neueren Zeitstempel: Hat ein anderes Gerät
zuletzt geschrieben, wird dessen Stand übernommen — auch wenn er **weiter
hinten** liegt (z. B. weil dort bewusst zurückgespult wurde). Bei älteren
Servern ohne Zeitstempel wird nur ein weiter fortgeschrittener Serverstand
übernommen. Nicht abgedeckt ist echtes *gleichzeitiges* Hören auf zwei
Geräten — dann gewinnt schlicht, wer zuletzt schreibt.

Jedes Fortschritts-Update schickt immer einen vollständigen Datensatz
(aktuelle Zeit, Dauer und Abschluss-Status zusammen), nie ein Teil-Update —
ein Teil-Update überlässt dem Server, was er mit den fehlenden Feldern macht,
was in der Vergangenheit schon zu echtem Fortschrittsverlust geführt hat,
wenn nur das Abschluss-Flag allein umgeschaltet wurde.

## Bewusst nicht enthalten

Multi-User, Podcasts, Metadaten-Bearbeitung, Server-/
Bibliotheksverwaltung.

## Voraussetzungen

- Xcode mit verfügbarem iOS-26-SDK (zwingend zum Bauen, da Mini-Player und
  Such-Button Apples Liquid-Glass-API hinter einer Verfügbarkeitsprüfung
  nutzen), Swift 5.9+
- Deployment-Ziel weiterhin iOS/iPadOS 17+ — die App läuft zur Laufzeit auch
  auf älteren iOS-Versionen, dort greift dann automatisch ein einfaches,
  durchscheinendes Material statt Liquid Glass
- Ein laufender Audiobookshelf-Server und deine Zugangsdaten oder ein API-Token
- Eine Apple-ID zum Signieren (kostenlos genügt; siehe Hinweis zur 7-Tage-
  Signatur unten)

## Lizenz

MIT — siehe [LICENSE](LICENSE).

---

## 1. Anmelde-Optionen

Die App meldet sich entweder mit **Benutzername und Passwort** an (Standard —
sie tauscht beides per `/login` gegen einen Token und speichert nur den Token
im Schlüsselbund) oder direkt mit einem **API-Token**.

Hinweis für Server mit dem neuen JWT-Auth-System (ab v2.26.0): Der
Passwort-Login bekommt dort einen kurzlebigen Access-Token, die Sitzung kann
also ablaufen und zurück zum Setup führen. Auf solchen Servern ist ein
API-Key die dauerhaftere Wahl.

So findest du deinen Token:

- **Ältere Server-Versionen:** Weboberfläche → Einstellungen → Benutzer →
  deinen Account anklicken → Token wird angezeigt.
- **Neuere Server-Versionen:** Weboberfläche → Einstellungen → API-Keys →
  neuen Key erzeugen.

Falls unsicher, welche Variante dein Server hat: einfach beides probieren,
einer der beiden Wege existiert garantiert.

---

## 2. Bauen & installieren

Das Repository enthält das komplette Xcode-Projekt — nichts muss zusammengebaut werden:

1. Repo klonen und **`Maer.xcodeproj`** öffnen (Xcode mit iOS-26-SDK).
2. **Signing** (Target `ABSPlayer` → Signing & Capabilities):
   - **Team:** deine Apple-ID — kostenlos reicht (siehe Hinweis unten)
   - **Bundle Identifier:** auf etwas Eigenes ändern, z. B. `de.deinname.maer`, und zwar auf BEIDEN Targets (`ABSPlayer` und `MaerWidgetsExtension` — die Widget-ID muss ein Kind der App-ID bleiben, z. B. `de.deinname.maer.widgets`)
   - In `Sources/Networking/KeychainStore.swift` die Konstante `service` auf denselben Bundle Identifier setzen.
3. iPhone anschließen, als Ziel wählen (Background-Audio testet sich auf echten Geräten deutlich verlässlicher als im Simulator), ▶ drücken.
4. Auf dem iPhone ggf. einmalig unter **Einstellungen → Allgemein → VPN & Geräteverwaltung** der Apple-ID vertrauen.

Background Audio, das Live-Activity-Widget-Target, die CarPlay-Szene und iPhone-/iPad-Unterstützung sind im Projekt bereits konfiguriert.

**Kostenlose Apple-ID ohne Developer Program:** Die App läuft 7 Tage pro Installation, danach einmal über Xcode neu bauen. **CarPlay im echten Auto** braucht zusätzlich Apples CarPlay-Audio-Entitlement (developer.apple.com/contact/carplay, bezahlter Account) — der CarPlay-Simulator (`I/O → External Displays → CarPlay`) funktioniert ohne.

## 3. In der App einloggen

- Server: `dein-server.example.com` (das `https://` wird automatisch ergänzt)
- Dann entweder Benutzername + Passwort, oder ein API-Token aus Schritt 1

---

## iPad-Unterstützung

iPhone und iPad sind im Projekt beide aktiviert. Das Bibliotheks-Grid passt sich automatisch der verfügbaren Breite an — mehr
Spalten auf dem iPad, nochmal mehr im Querformat — und berechnet sich bei
jeder Drehung sauber neu. Im iPhone-Hochformat blendet die Mini-Leiste ihre
zusätzlichen Transport-Buttons (Vor-/Zurückspulen, AirPlay) aus, damit mehr
Platz für den Buchtitel bleibt; auf dem iPad bzw. im iPhone-Querformat
erscheinen sie automatisch wieder.

```
Sources/
├── ABSPlayerApp.swift              Einstiegspunkt + AppDelegate für Background-Download-Events
├── AppSession.swift                Prozessweite Session (Player/Bibliothek, geteilt mit CarPlay)
├── AppShortcuts.swift              Siri App Intents (Weiterhören, bestimmtes Buch abspielen)
├── CarPlay/
│   └── CarPlaySceneDelegate.swift  CarPlay-Tabs (Weiter hören/Downloads/Bibliothek) + Now Playing
├── Models/
│   ├── AudiobookshelfModels.swift  Codable-Structs für die Audiobookshelf-API
│   ├── SyncRules.swift             Reine, getestete Sync-Entscheidungsregeln + Multi-Track-Zeitrechnung
│   ├── PlaybackActivityAttributes.swift  Gemeinsamer Live-Activity-Vertrag (App + Widget-Extension)
│   └── AppStorageKeys.swift        Zentrale UserDefaults-Keys inkl. Aufräumen der pro-Buch-Keys
├── Networking/
│   ├── APIClient.swift             Alle HTTP-Calls
│   ├── KeychainStore.swift         Sicherer Speicher für Server-URL + Token
│   ├── DownloadManager.swift       Mehrteilige Offline-Downloads + deren Metadaten-Cache
│   ├── FileDownloader.swift        Geteilte Background-URLSession mit Fortschrittsanzeige
│   ├── ImageCache.swift            Cover-Cache: Speicher + purgebarer Cache + persistenter Ordner für Downloads
│   ├── NetworkMonitor.swift        Fortlaufende Netzwerk-Beobachtung (Auto-Reconnect)
│   ├── NetworkStatus.swift         Einmaliger WLAN-Check + geteilte Offline-Fehler-Erkennung
│   ├── BookmarkQueue.swift         Offline-Warteschlange + Cache für Lesezeichen
│   └── SyncQueue.swift             Persistente Warteschlange für gescheiterte Updates
│                                   (Storage/API hinter Protokollen, testbar)
├── ViewModels/
│   ├── AuthViewModel.swift         Setup-Screen-Logik
│   ├── LibraryViewModel.swift      Bücherliste + Fortschritt, Sortierung, Serien-Gruppierung,
│   │                               Offline-Cache
│   ├── PlayerCoordinator.swift     Hält die aktive Session über Navigation hinweg am
│   │                               Leben, offline-fähig, Basis für Mini-Player
│   ├── PlayerViewModel.swift       AVQueuePlayer, Multi-Track-Queue, Seek/Skip, Kapitel
│   ├── PlayerViewModel+Sync.swift  Sync-Politik: Timer, Reentrancy-Guard, Konflikte, Abgleich
│   ├── PlayerViewModel+SleepTimer.swift   Sleep-Timer inkl. Lautstärke-Fade
│   ├── PlayerViewModel+LiveActivity.swift Live Activity starten/aktualisieren/beenden
│   └── PlayerViewModel+NowPlaying.swift   Lockscreen-Befehle, NowPlaying-Info, Artwork
└── Views/
    ├── SetupView.swift             Server + Passwort- oder Token-Anmeldung
    ├── SettingsView.swift          Wiedergabe, Darstellung, Speicher, Sync, Server
    ├── RootView.swift              Umschalten Setup ↔ Bibliothek
    ├── LibraryView.swift           Bücherliste, Sortierung/Filter, Sektionen, adaptives Grid
    ├── SearchOverlay.swift         Vollflächiges Glas-Such-Sheet (Echtzeit, Bereiche, Drill-down)
    ├── FullPlayerOverlay.swift     Ziehbares Liquid-Glass-Sheet mit dem vollen Player
    ├── SeriesStackCell.swift       Serien-Stapel-Kachel (gefächerte Cover + Zähler-Badge)
    ├── BookDetailScreen.swift      Buchdetailseite, Download, Als-gehört, Play/Pause
    ├── BookCoverView.swift         Cover mit Fortschrittsbalken + Status-Abzeichen
    ├── BookGridComponents.swift    Geteilte Grid-Zelle + Kontextmenü, Autoren-/Genre-Browsing
    ├── BookmarksSheet.swift        Lesezeichen-Sheet im Player (anlegen/springen/löschen)
    ├── CachedAsyncImage.swift      AsyncImage-Ersatz, nutzt ImageCache
    ├── MiniPlayerBar.swift         Persistente, schwebende Glas-Mini-Player-Leiste
    ├── FloatingSearchButton.swift  Schwebender Glas-Button, öffnet das Such-Overlay
    ├── AdaptiveGlassBackground.swift  Geteiltes Liquid-Glass-Styling mit Material-Rückfall
    ├── AirPlayButton.swift         AirPlay-Routenwahl
    ├── PlayerScreen.swift          Voller Player, zeigt die Coordinator-Session
    ├── PlayerView.swift            Player-UI (Audible-Stil)
    ├── CoverColorLoader.swift      Extrahiert Akzentfarbe aus dem Cover
    ├── ChapterListView.swift       Kapitelliste als Sheet
    └── Haptics.swift               Kleiner Helfer für haptisches Feedback
```

**Architektur-Hinweis Mini-Player:** Der `PlayerCoordinator` lebt in
`LibraryView` und überlebt Navigation. Die Wiedergabe wird beim Verlassen
des Player-Screens nicht gestoppt — nur explizit beim Öffnen eines anderen
Buchs.

Verwendete API-Endpunkte:

| Zweck | Endpoint |
|---|---|
| Bibliotheken | `GET /api/libraries` |
| Bücherliste | `GET /api/libraries/{id}/items?minified=1` |
| Buchdetails + Kapitel + Fortschritt | `GET /api/items/{id}?expanded=1` |
| Fortschritt schreiben | `PATCH /api/me/progress/{itemId}` |
| Fortschritt für die ganze Bibliothek | `GET /api/me` |
| Passwort-Anmeldung | `POST /login` |
| Lesezeichen | `GET /api/me`, `POST/DELETE /api/me/item/{id}/bookmark…` |
| Cover | `GET /api/items/{id}/cover?token=...` |
| Audio-Stream | direkte `contentUrl` aus den Track-Daten, mit `Authorization: Bearer` Header |

## Über dieses Projekt
Mär ist mit Unterstützung von KI entwickelt.
