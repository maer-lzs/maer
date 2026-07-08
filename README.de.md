# Hörregal

Ein schlanker, quelloffener iOS-/iPad-Client für [Audiobookshelf](https://www.audiobookshelf.org/).
Fokus auf genau eine Sache: **verlässlicher Fortschritts-Sync** über mehrere
Geräte hinweg, ohne dass ein Buch versehentlich auf 0 zurückgesetzt wird —
auch komplett offline.

> Der Name spielt auf das „Regal" in Audiobookshelf an — Hörregal ist dein
> Hörbuch-Regal fürs iPhone und iPad. (Das Xcode-Projekt heißt intern
> weiterhin `ABSPlayer`; „Hörregal" ist nur der Anzeigename.)

Entstanden als privater Ersatz für einen Client, der beim Geräte-Wechsel
regelmäßig den Hörfortschritt verlor. Die App ist bewusst minimal gehalten:
kein Multi-User, keine Podcasts, keine Server-Verwaltung — nur Hörbücher hören
und den Stand sauber synchronisieren, online wie offline.

> **Hinweis:** Dies ist ein privates Hobby-Projekt ohne Gewähr. Es ist nicht
> mit dem Audiobookshelf-Projekt affiliiert.

## Screenshots

| Bibliothek | Detail Book (iPhone) | Player (iPad) |
|---|---|---|
| ![Bibliothek](screenshots/iphone_bib.png) | ![Detail](screenshots/iphone_detail.png) | ![Player iPad](screenshots/ipad_player.png) |

## Features

- Login per API-Token (kompatibel mit altem und neuem Auth-System)
- Bibliothek als adaptives Cover-Grid (iPhone & iPad), das sich selbst so
  berechnet, dass es immer exakt zur verfügbaren Bildschirmbreite passt —
  ohne Überlappung, auch nach einer Bildschirm-Drehung
- Schwebender Such-Button (im Stil der Music-App), der sich bei Bedarf zu
  einem Suchfeld aufklappt, statt einer fest sichtbaren Suchleiste
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
- Ein laufender Audiobookshelf-Server und ein API-Token
- Eine Apple-ID zum Signieren (kostenlos genügt; siehe Hinweis zur 7-Tage-
  Signatur unten)

## Lizenz

MIT — siehe [LICENSE](LICENSE).

---

## 1. Warum kein Username/Passwort-Login?

Audiobookshelf hat in neueren Versionen (ab v2.26.0) das Auth-System auf
JWT mit Access-/Refresh-Token umgestellt. Das würde für eine „minimale" App
unnötige Komplexität bedeuten (Cookie-Handling, Token-Refresh-Logik).

So findest du deinen Token:

- **Ältere Server-Versionen:** Weboberfläche → Einstellungen → Benutzer →
  deinen Account anklicken → Token wird angezeigt.
- **Neuere Server-Versionen:** Weboberfläche → Einstellungen → API-Keys →
  neuen Key erzeugen.

Falls unsicher, welche Variante dein Server hat: einfach beides probieren,
einer der beiden Wege existiert garantiert.

---

## 2. Xcode-Projekt anlegen

1. Xcode öffnen → **File → New → Project**
2. **iOS → App** auswählen
3. Einstellungen:
   - Product Name: `ABSPlayer`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: **None** (kein Core Data)
   - Tests: Häkchen können raus, brauchst du hier nicht
4. Projekt irgendwo lokal speichern
5. Projekt-Datei anklicken → Target `ABSPlayer` → Tab **General** →
   **Minimum Deployments** auf **iOS 17.0** setzen

## 3. Dateien einfügen

1. Im Xcode-Projektnavigator die automatisch generierten Dateien
   `ContentView.swift` löschen (Move to Trash) — wird durch unsere Views ersetzt.
   `ABSPlayerApp.swift` (die automatisch generierte) ebenfalls löschen.
2. Den Ordner `Sources` aus diesem Download **komplett per Drag & Drop** in
   den Xcode-Projektnavigator ziehen (auf den obersten Projekt-Eintrag).
3. Im erscheinenden Dialog:
   - ✅ **Copy items if needed**
   - ✅ **Create groups**
   - ✅ Target „ABSPlayer" ist angehakt
4. Du solltest jetzt in Xcode die Gruppen `Models`, `Networking`,
   `ViewModels`, `Views` sowie `ABSPlayerApp.swift` sehen.

**Wenn du bei einem späteren Update nur einzelne Dateien ersetzt, statt das
Projekt neu aufzusetzen:** Zieh neue Dateien nicht über noch vorhandene
gleichnamige alte — macOS legt dann eine nummerierte Kopie an
(`Datei 2.swift`) statt zu überschreiben, und Xcode zeigt danach auf die
falsche physische Datei. Entweder den Inhalt jeder geänderten Datei direkt in
Xcode ersetzen, oder die alte Gruppe vorher löschen (Move to Trash) und die
Ersatzdatei danach frisch reinziehen.

## 4. Background Audio aktivieren

1. Projekt-Datei anklicken → Target `ABSPlayer` → Tab **Signing & Capabilities**
2. **+ Capability** → **Background Modes** hinzufügen
3. Häkchen bei **Audio, AirPlay, and Picture in Picture** setzen

Ohne diesen Schritt pausiert die Wiedergabe, sobald der Bildschirm gesperrt
wird oder die App in den Hintergrund geht.

## 5. Signing (mit kostenloser Apple-ID reicht)

1. Im selben Tab **Signing & Capabilities**:
   - **Team:** deine Apple-ID auswählen (Xcode → Settings → Accounts, falls
     noch nicht hinterlegt)
   - **Bundle Identifier:** etwas Eindeutiges, z. B. `de.deinname.absplayer`
2. In `KeychainStore.swift` die Konstante `service` auf denselben Bundle
   Identifier anpassen (Zeile mit `com.example.absplayer`).

**Wichtig bei kostenloser Apple-ID (kein Developer Program):** Die App läuft
nur 7 Tage auf deinem Gerät, danach muss sie einmal über Xcode neu gebaut
werden (Gerät anschließen, ▶ drücken). Für eine App, die nur du privat
nutzt, ist das ein akzeptabler Kompromiss.

## 5b. Anzeigenamen setzen (optional)

Der Name unter dem App-Icon lässt sich unabhängig vom internen Projektnamen
setzen:

1. Projekt-Datei → Target `ABSPlayer` → Tab **General**
2. Feld **Display Name** auf `Hörregal` setzen.

Damit erscheint die App auf dem Homescreen als „Hörregal", während das Projekt
in Xcode weiterhin `ABSPlayer` heißt (das intern umzubenennen ist fummelig und
lohnt nicht).

## 6. Auf dein iPhone bauen

1. iPhone per Kabel anschließen (oder WLAN-Debugging einrichten)
2. Als Ziel-Gerät oben in Xcode dein iPhone auswählen (nicht Simulator —
   Audio im Hintergrund testet sich auf echten Geräten deutlich zuverlässiger)
3. ▶ drücken
4. Auf dem iPhone ggf. einmalig **Einstellungen → Allgemein → VPN & Geräteverwaltung**
   → deiner Apple-ID vertrauen

## 7. In der App einloggen

- Server: `dein-server.example.com` (das `https://` wird automatisch ergänzt)
- API-Token: aus Schritt 1

---

## iPad-Unterstützung

Die App ist für iPhone und iPad ausgelegt. Damit sie auf dem iPad installiert
werden kann, muss im Ziel iPad als unterstütztes Gerät aktiv sein:

1. Projekt-Datei → Target **ABSPlayer** → Tab **General**
2. Unter **Supported Destinations** sollte **iPad** gelistet sein (bei neuen
   SwiftUI-Projekten standardmäßig aktiv). Falls nicht: **+** → iPad hinzufügen.
3. Unter **Deployment Info** ggf. **iPhone Orientation** und **iPad
   Orientation** prüfen — für einen Hörbuch-Player reichen Hoch- und Querformat.

Das Bibliotheks-Grid passt sich automatisch der verfügbaren Breite an — mehr
Spalten auf dem iPad, nochmal mehr im Querformat — und berechnet sich bei
jeder Drehung sauber neu. Im iPhone-Hochformat blendet die Mini-Leiste ihre
zusätzlichen Transport-Buttons (Vor-/Zurückspulen, AirPlay) aus, damit mehr
Platz für den Buchtitel bleibt; auf dem iPad bzw. im iPhone-Querformat
erscheinen sie automatisch wieder.

```
Sources/
├── ABSPlayerApp.swift              Einstiegspunkt
├── Models/                         Codable-Structs für die Audiobookshelf-API
├── Networking/
│   ├── APIClient.swift             Alle HTTP-Calls
│   ├── KeychainStore.swift         Sicherer Speicher für Server-URL + Token
│   ├── DownloadManager.swift       Mehrteilige Offline-Downloads + deren Metadaten-Cache
│   ├── FileDownloader.swift        Geteilte Background-URLSession mit Fortschrittsanzeige
│   ├── ImageCache.swift            Cover-Cache: Speicher + purgebarer Cache + persistenter Ordner für Downloads
│   ├── NetworkMonitor.swift        Fortlaufende Netzwerk-Beobachtung (Auto-Reconnect)
│   └── NetworkStatus.swift         Einmaliger WLAN-Check + geteilte Offline-Fehler-Erkennung
│   └── SyncQueue.swift             Persistente Warteschlange für offline gescheiterte Updates
├── ViewModels/
│   ├── AuthViewModel.swift         Setup-Screen-Logik
│   ├── LibraryViewModel.swift      Bücherliste + Fortschritt, Sortierung, Offline-Cache
│   ├── PlayerCoordinator.swift     Hält die aktive Session über Navigation hinweg am
│   │                               Leben, offline-fähig, Basis für Mini-Player
│   └── PlayerViewModel.swift       AVQueuePlayer, Multi-Track, Sync-Kernregel, Kapitel,
│                                   Sleep-Timer
└── Views/
    ├── SetupView.swift             Server + Token eingeben
    ├── RootView.swift              Umschalten Setup ↔ Bibliothek
    ├── LibraryView.swift           Bücherliste, Suche, Sortierung/Filter, adaptives Grid
    ├── BookDetailScreen.swift      Buchdetailseite, Download, Als-gehört, Play/Pause
    ├── BookCoverView.swift         Cover mit Fortschrittsbalken + Status-Abzeichen
    ├── CachedAsyncImage.swift      AsyncImage-Ersatz, nutzt ImageCache
    ├── MiniPlayerBar.swift         Persistente, schwebende Glas-Mini-Player-Leiste
    ├── FloatingSearchButton.swift  Aufklappbarer Such-Button
    ├── AdaptiveGlassBackground.swift  Geteiltes Liquid-Glass-Styling mit Material-Rückfall
    ├── AirPlayButton.swift         AirPlay-Routenwahl
    ├── PlayerScreen.swift          Voller Player, zeigt die Coordinator-Session
    ├── PlayerView.swift            Player-UI (Audible-Stil)
    ├── CoverColorLoader.swift      Extrahiert Akzentfarbe aus dem Cover
    ├── ChapterListView.swift       Kapitelliste als Sheet
    └── Haptics.swift               Kleiner Helfer für haptisches Feedback
```

**Architektur-Hinweis Mini-Player:** Der `PlayerCoordinator` lebt in
`LibraryView` und überlebt Navigation. Die Wiedergabe wird weder beim
Verlassen des Player-Screens gestoppt, noch wenn die Mini-Leiste vorübergehend
ausgeblendet ist (z. B. hinter einem aufgeklappten Suchfeld auf dem iPhone) —
gestoppt wird nur explizit beim Öffnen eines anderen Buchs.

Verwendete API-Endpunkte:

| Zweck | Endpoint |
|---|---|
| Bibliotheken | `GET /api/libraries` |
| Bücherliste | `GET /api/libraries/{id}/items` |
| Buchdetails + Kapitel + Fortschritt | `GET /api/items/{id}?expanded=1` |
| Fortschritt schreiben | `PATCH /api/me/progress/{itemId}` |
| Fortschritt für die ganze Bibliothek | `GET /api/me` |
| Cover | `GET /api/items/{id}/cover?token=...` |
| Audio-Stream | direkte `contentUrl` aus den Track-Daten, mit `Authorization: Bearer` Header |

## Über dieses Projekt
Hörregal ist mit Unterstützung von KI entwickelt.
