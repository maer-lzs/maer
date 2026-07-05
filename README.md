# Hörregal

Ein schlanker, quelloffener iOS-/iPad-Client für [Audiobookshelf](https://www.audiobookshelf.org/).
Fokus auf genau eine Sache: **verlässlicher Fortschritts-Sync** über mehrere
Geräte hinweg, ohne dass ein Buch versehentlich auf 0 zurückgesetzt wird.

> Der Name spielt auf das „Regal" in Audiobookshelf an — Hörregal ist dein
> Hörbuch-Regal fürs iPhone und iPad. (Das Xcode-Projekt heißt intern
> `ABSPlayer`.

Entstanden als privater Ersatz für einen Client, der beim Geräte-Wechsel
regelmäßig den Hörfortschritt verlor. Die App ist bewusst minimal gehalten:
kein Multi-User, keine Podcasts, keine Server-Verwaltung — nur Hörbücher hören
und den Stand sauber synchronisieren.

> **Hinweis:** Dies ist ein privates Hobby-Projekt ohne Gewähr. Es ist nicht
> mit dem Audiobookshelf-Projekt affiliiert.

## Features

- Login per API-Token (kompatibel mit altem und neuem Auth-System)
- Bibliothek als adaptives Cover-Grid (iPhone & iPad), mit fester Suchleiste,
  Sortierung (Titel/Autor/zuletzt hinzugefügt) und Filter (alle/unfertig/fertig)
- „Weiter hören"- und „Kürzlich hinzugefügt"-Sektionen
- Fortschrittsbalken pro Buch, „Abgeschlossen"-Markierung
- Buchdetailseite mit Beschreibung
- Persistente Mini-Player-Leiste mit eigenem Fortschrittsbalken; stellt die
  zuletzt gehörte Session auch nach einem kompletten App-Neustart automatisch
  wieder her (pausiert, spielt nie von selbst los)
- Player im Audible-Stil: großes Cover, aus dem Cover abgeleiteter Farbverlauf,
  Kapitelmarken direkt auf dem Scrubber, Play/Pause/Scrub/±30s/Kapitel-Vor-
  Zurück, Wiedergabegeschwindigkeit, Sleep-Timer (feste Minuten oder bis
  Kapitelende), AirPlay, „Als gehört markieren", dezentes haptisches Feedback
- Background Audio, Lockscreen- und Dynamic-Island-Anzeige inkl. Cover
- **Sicherer Progress-Sync** (siehe unten) und Multi-Device-Abgleich

## Die Sync-Kernregel

Das Herzstück der App. Ein bewusst vom Nutzer ausgelöster Sprung (Scrubber,
Kapitel, ±30s, Lockscreen) gilt als gewollt und wird sofort synchronisiert —
auch nach hinten. Ein Warn-Dialog erscheint nur, wenn der Fortschritt **ohne
Nutzeraktion** um mehr als 120 Sekunden absackt (z. B. ein fehlerhafter
Client-Reset). Bei „Abbrechen" springt die Wiedergabe zurück zum zuletzt
gespeicherten Stand.

Beim Geräte-Wechsel gleicht die App vor jedem Play kurz mit dem Server ab: Wer
zuletzt auf einem anderen Gerät weitergehört hat, dessen Stand wird übernommen,
statt ihn zu überschreiben. Nicht abgedeckt ist echtes *gleichzeitiges* Hören
auf zwei Geräten — dann gewinnt schlicht, wer zuletzt schreibt.

## Bewusst nicht enthalten

Offline-Download, Multi-User, Podcasts, Metadaten-Bearbeitung, Server-/
Bibliotheksverwaltung.

## Voraussetzungen

- Xcode 15+ (Swift 5.9+), Ziel iOS/iPadOS 17+
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

-  Weboberfläche → Einstellungen → API-Keys →
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
   **Minimum Deployments** auf **iOS 17.0** setzen (der Code nutzt die
   neuere `onChange`-API)

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

Das Layout passt sich automatisch an: Die Bibliothek zeigt auf dem iPad ein
mehrspaltiges Cover-Grid (mehr Spalten im Querformat), Player und Detailseite
zentrieren ihren Inhalt in einer lesbaren Spalte statt über die volle Breite zu
laufen.



```
Sources/
├── ABSPlayerApp.swift        Einstiegspunkt
├── Models/                   Codable-Structs für die Audiobookshelf-API
├── Networking/
│   ├── APIClient.swift       Alle HTTP-Calls
│   └── KeychainStore.swift   Sicherer Speicher für Server-URL + Token
├── ViewModels/
│   ├── AuthViewModel.swift      Setup-Screen-Logik
│   ├── LibraryViewModel.swift   Bücherliste + Fortschritt laden
│   ├── PlayerCoordinator.swift  Hält die aktive Session über Navigation
│   │                            hinweg am Leben (Basis für Mini-Player)
│   └── PlayerViewModel.swift    AVPlayer, Sync-Kernregel, Kapitel, Sleep-Timer
└── Views/
    ├── SetupView.swift        Server + Token eingeben
    ├── RootView.swift         Umschalten Setup ↔ Bibliothek
    ├── LibraryView.swift      Bücherliste, Suche, Sektionen
    ├── BookCoverView.swift    Cover mit Fortschrittsbalken (wiederverwendet)
    ├── MiniPlayerBar.swift    Persistente Leiste am unteren Bildschirmrand
    ├── PlayerScreen.swift     Voller Player, zeigt die Coordinator-Session
    ├── PlayerView.swift       Player-UI (Audible-Stil)
    ├── CoverColorLoader.swift Extrahiert Akzentfarbe aus dem Cover
    └── ChapterListView.swift  Kapitelliste als Sheet
```

**Architektur-Hinweis Mini-Player:** Der `PlayerCoordinator` lebt in
`LibraryView` und überlebt Navigation — anders als früher wird die Wiedergabe
beim Verlassen des Player-Screens nicht mehr gestoppt. Gestoppt wird nur
explizit: beim Öffnen eines anderen Buchs oder über das X in der
Mini-Player-Leiste.

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

