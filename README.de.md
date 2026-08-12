<p align="center">
  <img src="docs/logo.png" alt="Mär App-Icon" width="128" height="128">
</p>

# Mär

Ein schlanker, quelloffener iOS-/iPad-Client für **selbst gehostetes Audio** — Hörbücher, Podcasts, Musik und Internetradio in einer App, mit einer Designsprache und einem Player.

Mär ist **server-first und offline-first**: Bibliothek, Metadaten, Cover und Fortschritt liegen auf deinen eigenen Servern und erreichen die App über **offene Standard-APIs ohne clientseitige API-Keys** — [Audiobookshelf](https://www.audiobookshelf.org/), Subsonic/OpenSubsonic, gpodder/mygpo, klassisches RSS und den offenen Radio-Browser-Katalog. Sein Fundament: **verlässlicher Fortschritts-Sync** über mehrere Geräte hinweg, ohne dass ein Buch versehentlich auf 0 zurückgesetzt wird — auch komplett offline.

> „Mär" ist ein altes Wort für Erzählung oder Geschichte — passend für einen
> Audio-Player. (Das Xcode-Projekt heißt intern weiterhin `ABSPlayer`;
> „Mär" ist nur der Anzeigename.)

Entstanden als privater Ersatz für einen Client, der beim Geräte-Wechsel regelmäßig den Hörfortschritt verlor. Inzwischen ist daraus ein universeller Client für das selbst gehostete, quelloffene Audio-Ökosystem geworden — auf einer Provider-Architektur, dabei bewusst fokussiert: kein Multi-User, keine Server-Verwaltung, nur hören und den Stand verlässlich synchronisieren, online wie offline.

> **Hinweis:** Dies ist ein privates Hobby-Projekt ohne Gewähr. Es ist nicht

**Zuhause:** <https://maer.fm> · **Quelltext:** <https://codeberg.org/LzS/maer>
> mit dem Audiobookshelf-Projekt affiliiert.

## Screenshots

| Bibliothek | Player | Musik |
|---|---|---|
| ![Bibliothek](screenshots/iphone_library.png) | ![Player](screenshots/iphone_player.png) | ![Musik](screenshots/iphone_music.png) |

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
- **Globale Suche über alle Quellen**: eine Suche erreicht Hörbücher,
  Podcasts, Musik und Radio zugleich. Eine stehende Scope-Leiste grenzt auf
  Bibliothek / Hörbücher / Podcasts / Musik / Radio ein; ein leeres Feld zeigt
  ein Browse-Deck (zuletzt gesucht, plus Einstiegs-Kacheln für
  Autoren/Serien/Genres, Künstler, Sendungen, Alben), Tippen liefert gerankte
  Ergebnisse je Typ. Podcast- und Radio-Scope blenden eine Katalog-Sektion ein
  — „Neue Shows" aus PodcastIndex/iTunes, Sender aus Radio Browser —, damit du
  abonnieren oder etwas noch nicht Vorhandenes abspielen kannst. Offline-fähig:
  jede Quelle durchsucht ihren Cache, aktuell nicht abspielbare Treffer werden
  gedimmt und markiert
- **Ohne Server loslegen**: Das Onboarding lässt dich die Anmeldung
  überspringen und sofort mit Podcasts (RSS) und lokalen Dateien starten;
  Quellen — Audiobookshelf, ein Musik-Server, Radio, gpodder-Sync — kommen
  später einzeln unter Einstellungen dazu, ihr Tab erscheint live
- **Start-Tab**: ein medienübergreifender Startbildschirm mit Fortsetzen,
  Wiederentdecken (länger pausiert / nächstes ungehörtes Serienbuch),
  Entdecken (nutzungsbasierte Empfehlungen) und einem dichten Grid der
  neuesten Folgen
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
  Design (iOS 26), mit kreisförmigem Fortschrittsring ums Cover; zusätzliche Transport-Buttons
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
- Einstellungen: Quellen und Sync je Dienst an einer tab-unabhängigen Stelle,
  Sprung-Intervall, Standard-Geschwindigkeit für neue Bücher,
  **Smart Rewind** (nach längerer Pause etwas früher wieder einsetzen),
  **automatisch das nächste ungehörte Serienbuch starten**, Darstellung
  (System/Hell/Dunkel), WLAN-Warnung abschaltbar, Speicherverwaltung,
  Benachrichtigungen, Hörstatistiken, App-Version
- **Sync-Verlauf** in den Einstellungen — eine Liste über alle Dienste
  (Audiobookshelf-Fortschritt, gpodder, iCloud, Musik-Bibliothek), mit einer
  „Zuletzt geprüft"-Zeile je Dienst und einem Ring der tatsächlichen
  Änderungen, Fehler und Massenlösch-Schutz-Ereignisse; ein sauberer Lauf ohne
  Änderung bleibt sichtbar, ohne den Ring zu füllen
- **Siri & Kurzbefehle**: „Weiterhören in Mär" und „Spiele *Buch* in
  Mär" (Buchnamen kommen aus dem Offline-Bibliothekscache), plus
  Home-Screen-Schnellaktion für das zuletzt gehörte Buch
- **CarPlay**: Hörbuch-Tabs (Weiter hören / Heruntergeladen / Bibliothek),
  plus ein Podcasts- und ein Musik-Tab, sobald diese Quellen eingerichtet sind,
  je mit Cover-Thumbnails und dem System-Now-Playing, teilt sich die Wiedergabe-
  Session mit dem Telefon — funktioniert auch beim Kaltstart im Auto
  (Offline-Cache als Rückfallebene); im Simulator sofort testbar, fürs
  echte Auto braucht es Apples CarPlay-Audio-Entitlement
  (developer.apple.com/contact/carplay)
- Adaptives Hell-/Dunkel-Design mit **dunkelgrauem Marken-Akzent**; jeder
  Medientyp trägt am Tab-Selektor seine eigene Farbe — Hörbücher orange,
  Podcasts lila, Musik rot, Radio cyan. Das Liquid-Glass-Chrome (Mini-Player,
  Suche, Toolbar-Buttons) bekommt im hellen Modus einen pastelligen Hauch
  der aktuellen Cover-Farbe; beim Buchwechsel taucht der Mini-Player kurz
  ab und federt mit neuer Farbe zurück
- Performance: Grid-Zellen dekodieren ein kleines abgeleitetes Thumbnail
  statt des vollen Covers — flüssiges Scrollen und deutlich weniger
  Speicher bei großen Bibliotheken; die Bücherliste kommt im minified-
  Format vom Server
- **Barrierefreiheit**: volle Dynamic-Type-Unterstützung bis zu den
  Accessibility-Textgrößen — Bedien-Reihen brechen in ein Zwei-Spalten-Raster
  um, feste Kacheln bekommen Zeilen, hartkodierte Maße skalieren über
  `@ScaledMetric`; VoiceOver-Labels auf allen Bedienelementen und
  44-pt-Trefferflächen; über Gerätegrößen von der 375-pt-Klasse bis iPad und
  in beiden Ausrichtungen geprüft
- Härtung: Speicherplatz-Check vor Downloads, Magic-Byte-Container-
  Erkennung mit automatischer Endungs-Reparatur (unit-getestet),
  automatische Erholung bei mitten in der Wiedergabe kaputten Tracks statt
  stiller Stille, VoiceOver-Labels auf allen Transport-Buttons

## Podcasts

Version 2.0 macht Mär neben Hörbüchern zu einem vollwertigen **Podcast-Client**. Podcasts sind ein eigener Medientyp hinter demselben Provider-Protokoll — Hörbuch-Wiedergabe und -Sync bleiben unberührt; ein eigener Podcast-Tab erscheint erst, sobald es Abos gibt.

- **Drei Abo-Quellen, abgeglichen:** lokale **RSS**-Feeds, optional **Audiobookshelf**-Podcast-Libraries und ein selbst gehosteter **gpodder/mygpo**-Server (z. B. [oPodSync](https://github.com/kd2org/opodsync)) als gleichwertiges Backend neben iCloud und ABS. Abos, Abbestellungen und Gehört-Status bleiben über alle drei in einem sauberen, abgeglichenen Stand — ein robustes Abbestellen entfernt einen Feed überall zugleich
- **Apple-Podcasts-Import** bestehender Abos
- **Home im Apple-Podcasts-Stil:** eine „Fortsetzen"-Reihe mit reichen Karten (Restzeit · zuletzt gehört · Kapitel), nutzungsbasierte Empfehlungen, die Als-Nächstes-Queue, eine Premium-Reihe, heruntergeladene Folgen und ein „Zuletzt aktualisiert"-Sendungsraster mit rotem Badge für neue, ungehörte Folgen
- **Nutzungsbasierte Empfehlungen:** sprach- und themenbewusst aus deiner eigenen Bibliothek und Hörzeit, nach Autor/Publisher erweitert und im Round-Robin durchmischt, damit kein Anbieter dominiert
- **Pro-Sendung-Einstellungen:** Inbox-Modus, nur neueste N behalten (mit Auto-Löschen alter Downloads), Auto-Download neuer Folgen und Benachrichtigungen je Sendung
- **Premium-Feeds** per HTTP-Basic-Auth je Feed, im Schlüsselbund gespeichert
- **Reiche Metadaten** aus RSS / Podcasting 2.0 und der PodcastIndex-API: Staffeln, Folgentyp, Explicit, Gäste/Personen, Transkripte, Funding-Links, Kategorien
- **Background-Refresh** (`BGAppRefreshTask`) mit gebündelten Benachrichtigungen je Sendung, Offline-Downloads, Queue, Kapitel, hochauflösende Feed-Cover, CarPlay und ein „Als Nächstes"-Home-Widget
- Hör-History-Brücke zwischen RSS- und ABS-Podcast-Folgen (geteilter Fortschritt, optionaler Server-Push)

## Musik

Version 2.1 ergänzt **Musik** als dritten Medientyp, für **Subsonic-/OpenSubsonic**-kompatible Server (Navidrome, Gonic, Airsonic). Wie Podcasts liegt sie hinter demselben Provider-Protokoll — Hörbuch- und Podcast-Wiedergabe bleiben unberührt; ein Musik-Tab erscheint, sobald unter Einstellungen → Musik ein Server eingerichtet ist.

- **Medientyp-eigenes Browsen** (nicht das Hörbuch-Grid): Reihen für „Kürzlich hinzugefügt" und „Häufig gespielt", Browse-Zeilen für Künstler und Playlists sowie das volle Album-Raster, im Hintergrund seitenweise nachgeladen. Ein Album ist ein mehrspuriges Item — ein Tap auf einen Track spielt das ganze Album ab dieser Stelle, über denselben Player wie alles andere.
- **Künstler-Seiten** (OpenSubsonic): Künstlerbild und Biografie, Top-Songs (Tap spielt), ähnliche Künstler begrenzt auf die, die es in deiner eigenen Bibliothek tatsächlich gibt. Alles best-effort — ein Server ohne Metadaten-Agent zeigt einfach weniger Sektionen.
- **Album-Detail**: Notes, Jahr · Genre, ein Favoriten-Umschalter (Herz) und Offline-Download des ganzen Albums. Ein hochauflösendes Front-Cover kommt vom **Cover Art Archive**, wenn das Album eine MusicBrainz-ID trägt (unter Beachtung von User-Agent und der 1-Anfrage-pro-Sekunde-Regel).
- **Songtexte im Player**: zuerst vom Server (`getLyricsBySongId`), mit dem offenen Dienst **LRCLIB** als Fallback (ein ±5-s-Dauer-Check sichert dessen unscharfes Matching ab); synchrone Texte heben die aktuelle Zeile hervor und folgen der Wiedergabe (Tap zum Springen), unsynchrone erscheinen als statischer Text. Ergebnisse — auch Negativtreffer — werden auf der Festplatte gecacht, damit Button und Panel sofort reagieren und offline funktionieren.
- **Favoriten** (Herz an/aus) und **Scrobbeln beim Abspielen**: die Server-eigenen Playcounts, und Last.fm / ListenBrainz, wenn der Server Scrobbles weiterleitet.
- Bewusst kein serverseitiger Positions-Sync für Musik (braucht keinen); Wiedergabe, Downloads und ein CarPlay-Musik-Tab nutzen den geteilten Kern. Die Metadaten-Endpunkte sind, wo vorhanden, gegen die OpenSubsonic-Erweiterungen verifiziert.

## Radio

Mär spielt auch **Internetradio**, als vierten Medientyp hinter demselben Provider-Protokoll. Ein Radio-Tab erscheint, sobald die Quelle unter Einstellungen → Quellen → Radio aktiviert ist.

- **Zwei Quellen:** der offene **[Radio-Browser](https://www.radio-browser.info/)**-Katalog (durchsuchbar, ohne Account) und **eigene Stream-URLs** (z. B. ein AzuraCast-Mount) von Hand hinzugefügt. Codec-/Bitraten-Varianten desselben Senders im Katalog werden auf einen einzigen Treffer gefaltet (die höchste Bitrate).
- **Ehrliche Live-Abstraktion:** ein Live-Stream hat keine Dauer, kein Seek, keinen Fortschritt und keinen Download — der Player wechselt in ein Live-Layout: eine LIVE-Markierung statt Scrubber, nur Play/Pause und ein uhrzeitbasierter Sleep-Timer. Keine Fortschritts-Maschinerie läuft, und Radio landet nie in der Als-Nächstes-Queue.
- **ICY-Now-Playing:** die aktuelle Sendung aus den ICY-Metadaten des Streams erscheint im Player (unter dem Sendernamen) und auf dem Lockscreen.
- **Favoriten, eigene Sender und ein Verlauf-Ring**, auf dem Gerät gespeichert; ein aus der Sender-Farbe abgeleiteter Artwork-Platzhalter (mit Sender-Favicon, falls der Stream eins liefert) wird zwischen Zeilen und Player geteilt — so wird nie ein winziges Favicon im großen Player hochskaliert.

## Kompatibel mit

Mär spricht mit Servern über deren Standard-APIs und funktioniert daher mit mehr als einer Implementierung je Typ. Nur wirklich Verifiziertes wird als solches genannt; „sollte funktionieren" heißt standardkompatibel, aber hier nicht getestet — keine Kompatibilitätsversprechen für nicht ausprobierte Server.

- **Audiobookshelf** — Hörbücher und Podcasts (verifiziert).
- **Subsonic-/OpenSubsonic**-Musikserver — verifiziert gegen **Navidrome**; andere Subsonic-kompatible Server (Gonic, Airsonic, …) sollten funktionieren, sind aber nicht einzeln getestet.
- **gpodder-/mygpo**-Sync — verifiziert gegen **oPodSync**; andere gpodder-kompatible Backends sollten funktionieren.
- **RSS / Podcasting 2.0**-Feeds, das **PodcastIndex**-Verzeichnis und der offene **Radio-Browser**-Katalog für Sender.

Jellyfin-Unterstützung ist eine mögliche Zukunftsrichtung, kein aktuelles Feature.

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

Multi-User, Metadaten-Bearbeitung, Server-/Bibliotheksverwaltung. Ebenfalls nicht gebaut (heute): Playlists anlegen oder bearbeiten, ein Equalizer und eine Apple-Watch-App.

## Voraussetzungen

- Xcode mit verfügbarem iOS-26-SDK (zwingend zum Bauen, da die App Apples
  Liquid-Glass-API nutzt)
- Deployment-Ziel **iOS/iPadOS 26.5** (Mindest-Laufzeitversion)
- Eine Audioquelle — aber **zum Loslegen ist kein Server nötig**:
  - du kannst **ganz ohne Server starten** und sofort Podcasts (RSS) und
    importierte lokale Dateien nutzen
  - **Audiobookshelf** für Hörbücher und Podcasts — mit deinen Zugangsdaten
    oder einem API-Token
  - und/oder ein **Subsonic-/OpenSubsonic**-kompatibler Musik-Server
    (Navidrome, Gonic, Airsonic) für den Musik-Tab
  - **Internetradio** braucht keinen Server — der öffentliche
    Radio-Browser-Katalog sowie beliebige eigene Stream-URLs
  - Podcast-Abos können zusätzlich über einen selbst gehosteten
    **gpodder-/oPodSync**-Server synchronisieren (optional; iCloud und
    Audiobookshelf sind die anderen Backends)
- Eine Apple-ID zum Signieren (kostenlos genügt; siehe Hinweis zur 7-Tage-
  Signatur unten)

## Lizenz

GPL-3.0-or-later — siehe [LICENSE](LICENSE). Bis v2.1 wurde Mär unter der
MIT-Lizenz angeboten; ab diesem Commit gilt GPL-3.0-or-later. LICENSE-Dateien
in der älteren Historie sind historische Artefakte.

Mär steht unter der GPL-3.0. Zusätzlich gelten Bedingungen nach GPL-3.0
Abschnitt 7 — eine zusätzliche Erlaubnis für die Verteilung über
App-Vertriebskanäle und ein Vorbehalt an Name und Symbol: siehe
[LICENSE-ADDITIONAL-TERMS](LICENSE-ADDITIONAL-TERMS). Für die Verteilung über
den App Store gilt eine eigene Endnutzer-Vereinbarung anstelle der von Apple:
[docs/EULA.md](docs/EULA.md). Der Quelltext jeder veröffentlichten Fassung
bleibt unter <https://codeberg.org/LzS/maer> verfügbar.

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

Das Repository enthält das komplette Xcode-Projekt — nichts muss zusammengebaut werden.
**Mär baut ohne API-Schlüssel** (zwei optionale App-Schlüssel für Jamendo und
PodcastIndex werden aus `Config/AppKeys.local.xcconfig` gelesen, falls die Datei
existiert; ohne sie bleiben nur diese beiden Reihen weg) und hat **keine
Fremdabhängigkeiten** — kein Paketmanager-Schritt, nichts aufzulösen.

1. Repo klonen und **`Maer.xcodeproj`** öffnen (Xcode mit iOS-26-SDK).
2. **Signing** (Target `ABSPlayer` → Signing & Capabilities):
   - **Team:** deine Apple-ID — kostenlos reicht (siehe Hinweis unten)
   - **Bundle Identifier:** auf etwas Eigenes ändern, z. B. `de.deinname.maer`, und zwar auf BEIDEN Targets (`ABSPlayer` und `MaerWidgetsExtension` — die Widget-ID muss ein Kind der App-ID bleiben, z. B. `de.deinname.maer.widgets`)
   - In `Sources/Networking/KeychainStore.swift` die Konstante `service` auf denselben Bundle Identifier setzen.
3. iPhone anschließen, als Ziel wählen (Background-Audio testet sich auf echten Geräten deutlich verlässlicher als im Simulator), ▶ drücken.
4. Auf dem iPhone ggf. einmalig unter **Einstellungen → Allgemein → VPN & Geräteverwaltung** der Apple-ID vertrauen.

Background Audio, das Widget-Extension-Target, die CarPlay-Szene und iPhone-/iPad-Unterstützung sind im Projekt bereits konfiguriert.

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
├── Providers/
│   ├── AudioProvider.swift         Protokoll, das jede Audioquelle erfüllt (Login, Bibliothek,
│   │                               Suche, Stream, Download, Sync) — der Core sieht nur das
│   ├── ABSProvider.swift           Audiobookshelf als erster Provider
│   ├── LocalProvider.swift         Importierte lokale Audiodateien (kein Server)
│   ├── LocalLibrary.swift          Lokaler Datei-Index + AVAsset-Metadaten
│   ├── SubsonicProvider.swift      Subsonic/OpenSubsonic-Musik (Navidrome, Gonic, Airsonic)
│   ├── RadioProvider.swift         Internetradio (radio:-Namespace), Radio Browser + eigene URLs
│   ├── RSSProvider.swift           Podcasts: RSS-Episoden als Library-Items
│   ├── MaerPlaylists.swift         Mär-Playlists: der ZWEITE Playlist-Typ, mischt alle Kennungen
│   ├── ABSPodcastProvider.swift    Audiobookshelf-Podcast-Libraries (opt-in-Quelle)
│   ├── PodcastSubscriptions.swift  Feed-Store + RSS/Podcasting-2.0-Parser (XMLParser)
│   ├── PodcastSubscriptionSync.swift  Abgeglichenes Spiegeln lokal ↔ ABS
│   ├── PodcastDirectory.swift      Entdecken über PodcastIndex + iTunes-Charts
│   ├── PodcastRecommendationsStore.swift  Nutzungsbasiertes, thematisches Ranking
│   ├── ProviderSearch.swift        SearchableProvider-Capability + Suche je Quelle
│   ├── PlayQueue.swift             Globale, medienübergreifende Als-Nächstes-Queue
│   └── PodcastImport.swift         Apple-Podcasts-Abo-Import
├── CarPlay/
│   └── CarPlaySceneDelegate.swift  CarPlay-Tabs (Hörbücher + Podcasts + Musik) + Now Playing
├── Models/
│   ├── AudiobookshelfModels.swift  Codable-Structs für die Audiobookshelf-API
│   ├── SubsonicModels.swift        Codable-Structs für die Subsonic/OpenSubsonic-API
│   ├── RadioModels.swift           Foundation-only Radio-Kern (Mapping, ICY-Parser, Store)
│   ├── MediaType.swift             Die vier Medientypen (Hörbücher/Podcasts/Musik/Radio)
│   ├── SyncRules.swift             Reine, getestete Sync-Entscheidungsregeln + Multi-Track-Zeitrechnung
│   ├── SyncHistory.swift           Reine Sync-Verlaufseinträge + Ring-Puffer
│   ├── HomeSections.swift          Home-Aggregation (Aktualität, faires Verschränken)
│   ├── RediscoverSections.swift    Wiederentdecken (pausiert / ungehört / nächstes in Serie)
│   ├── SearchModels.swift          Such-Ergebnis-/Ranking-Typen
│   ├── AppStorageKeys.swift        Zentrale UserDefaults-Keys, eine Aktivierungs-Antwort je Quelle
│   ├── SourceMap.swift             Pur: die fünf Bereiche und was jeder braucht
│   ├── MaerPlaylistMerge.swift     Pur: Merge je Liste, Rettungskopie, Grabsteine
│   └── PodcastAutoDownloadRules.swift  Pur: was das Aufräumen anfassen darf
├── Networking/
│   ├── APIClient.swift             Alle HTTP-Calls
│   ├── AppUserAgent.swift          DIE eine Kennung gegenüber fremden Servern
│   ├── MaerPlaylistCloudSync.swift Mär-Playlists über deine eigenen Geräte (iCloud)
│   ├── KeychainStore.swift         Sicherer Speicher für Server-URL + Token
│   ├── DownloadManager.swift       Mehrteilige Offline-Downloads + deren Metadaten-Cache
│   ├── FileDownloader.swift        Geteilte Background-URLSession mit Fortschrittsanzeige
│   ├── ImageCache.swift            Cover-Cache: Speicher + purgebarer Cache + persistenter Ordner für Downloads
│   ├── SubsonicClient.swift        Subsonic/OpenSubsonic-API (Token+Salt-Auth, Streaming, Lyrics)
│   ├── CoverArtArchive.swift       Hochauflösende Album-Cover per MusicBrainz-ID (ratenbegrenzt)
│   ├── RadioBrowserClient.swift    Radio-Browser-Katalog-Client (Spiegel-Fallback)
│   ├── SyncHistoryStore.swift      Persistierter Sync-Verlauf + „Zuletzt geprüft" je Dienst
│   ├── NetworkMonitor.swift        Fortlaufende Netzwerk-Beobachtung (Auto-Reconnect)
│   ├── NetworkStatus.swift         Einmaliger WLAN-Check + geteilte Offline-Fehler-Erkennung
│   ├── BookmarkQueue.swift         Offline-Warteschlange + Cache für Lesezeichen
│   ├── SyncQueue.swift             Persistente Warteschlange für gescheiterte Updates
│   │                               (Storage/API hinter Protokollen, testbar)
│   ├── Retry.swift                 Backoff-Retry bei transienten Netzfehlern
│   ├── URLSession+Maer.swift       Geteilte Session mit sinnvollen Timeouts
│   ├── GPodderClient.swift         gpodder/mygpo-API-Client (Login, Abos, Episoden)
│   ├── GPodderSync.swift           3-Wege-Abgleich der gpodder-Abos + Play-Aktionen
│   ├── PodcastCloudSync.swift      iCloud-KV-Sync der lokalen Abos
│   ├── PodcastFeedAuth.swift       Pro-Feed-Basic-Auth für Premium-Feeds (Schlüsselbund)
│   ├── PodcastRefreshService.swift Hintergrund-Feed-Refresh + Neue-Folgen-Benachrichtigungen
│   └── PodcastServerSave.swift     Nachträgliches Server-Sichern gestreamter Feed-Folgen
├── ViewModels/
│   ├── AuthViewModel.swift         Setup-Screen-Logik
│   ├── GlobalSearchModel.swift     Quellenübergreifende Suche (Fan-out, Debounce, Teilergebnisse)
│   ├── LibraryViewModel.swift      Bücherliste + Fortschritt, Sortierung, Serien-Gruppierung,
│   │                               Offline-Cache
│   ├── PlayerCoordinator.swift     Hält die aktive Session über Navigation hinweg am
│   │                               Leben, offline-fähig, Basis für Mini-Player
│   ├── PlayerViewModel.swift       AVQueuePlayer, Multi-Track-Queue, Seek/Skip, Kapitel
│   ├── PlayerViewModel+Sync.swift  Sync-Politik: Timer, Reentrancy-Guard, Konflikte, Abgleich
│   ├── PlayerViewModel+SleepTimer.swift   Sleep-Timer inkl. Lautstärke-Fade
│   └── PlayerViewModel+NowPlaying.swift   Lockscreen-Befehle, NowPlaying-Info, Artwork
└── Views/
    ├── SetupView.swift             Erster Bildschirm: die Karte der Bereiche + „Ohne
    │                               Server loslegen"; enthält ABSLoginForm/ABSLoginPage
    │                               (die EINE Audiobookshelf-Anmeldung)
    ├── SourceMapCard.swift         DIE Karte der Bereiche — erster Bildschirm UND
    │                               Quellen-Übersicht der Einstellungen, plus SourceAreaPage
    ├── SettingsView.swift          Wiedergabe, Darstellung, Speicher, Sync, Server
    ├── RootView.swift              Umschalten Setup ↔ Bibliothek
    ├── LibraryView.swift           Bücherliste, Sortierung/Filter, Sektionen, adaptives Grid
    ├── HomeView.swift              Medienübergreifender Start-Tab (Fortsetzen/Wiederentdecken/Entdecken/Neueste)
    ├── SearchScreen.swift          Vollseitige globale Suche (Scope-Leiste, Browse-Deck, Katalog)
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
    ├── Haptics.swift               Kleiner Helfer für haptisches Feedback
    ├── MediaTabBar.swift           Medientyp-Umschalter Start/Hörbücher/Podcasts/Musik/Radio
    ├── MediaTile.swift             Geteilte Grid-Kachel (Home, neueste Folgen, Empfehlungen)
    ├── MediaRowContent.swift       Geteiltes Listen-Zeilen-Layout (Podcast-Folgen, Bücher, Sender)
    ├── SyncHistoryView.swift       Einstellungen: Sync-Verlauf („Zuletzt geprüft" + Änderungs-Ring)
    ├── ABSSourceView.swift         Audiobookshelf-Quellenseite (Zugang, Sync)
    ├── SubsonicSourceView.swift    Musik-Quellenseite (Server, Zugangsdaten, Sync)
    ├── RadioSourceView.swift       Radio-Quellenseite (aktivieren, eigene Stream-URLs)
    ├── PodcastsView.swift          Podcast-Home (Fortsetzen, Empfehlungen, Queue, Reihen)
    ├── PodcastSourceView.swift     Podcasts hinzufügen/importieren, Abo-Quellen wählen
    ├── Podcasts/                   Sendung, Folge, Queue, Discover, Pro-Sendung-Einstellungen, Karten
    ├── Music/                      Musik-Home, Album, Künstler, Playlists, Songtext-Panel
    └── Radio/                      Radio-Tab, Sender-Zeilen, geteiltes Radio-Artwork
```

**Architektur-Hinweis Mini-Player:** Der `PlayerCoordinator` lebt in
`LibraryView` und überlebt Navigation. Die Wiedergabe wird beim Verlassen
des Player-Screens nicht gestoppt — nur explizit beim Öffnen eines anderen
Buchs.

Verwendete API-Endpunkte:

| Zweck | Endpoint |
|---|---|
| Bibliotheken | `GET /api/libraries` |
| Bücherliste (progressives Paging) | `GET /api/libraries/{id}/items?minified=1&limit=&page=` |
| Fortsetzen-/Kürzlich-Reihen | `GET /api/libraries/{id}/personalized` |
| Buchdetails + Kapitel + Fortschritt | `GET /api/items/{id}?expanded=1` |
| Fortschritt schreiben | `PATCH /api/me/progress/{itemId}` |
| Fortschritt für die ganze Bibliothek | `GET /api/me` |
| Passwort-Anmeldung | `POST /login` |
| Suche (Bücher/Autoren/Serien) | `GET /api/libraries/{id}/search?q=` |
| Lesezeichen | `GET /api/me`, `POST/DELETE /api/me/item/{id}/bookmark…` |
| Cover | `GET /api/items/{id}/cover?token=...` |
| Audio-Stream | direkte `contentUrl` aus den Track-Daten, mit `Authorization: Bearer` Header |
| gpodder/mygpo-Sync | `POST /api/2/auth/{user}/login.json`, `GET/POST /api/2/subscriptions/{user}/{device}.json`, `GET/POST /api/2/episodes/{user}.json` |

Podcasts sprechen zusätzlich mit externen **RSS-Feeds**, der **PodcastIndex**-API und den **iTunes**-Charts (Entdecken/Metadaten, optionaler Key) und deinem selbst gehosteten **gpodder/mygpo**-Server.

Musik spricht mit deinem **Subsonic/OpenSubsonic**-Server (`ping`, `getAlbumList2`, `getAlbum`, `getArtists`, `getArtist`, `getArtistInfo2`, `getAlbumInfo2`, `getTopSongs`, `search3`, `getPlaylists`, `getLyricsBySongId`, `stream`, `getCoverArt`, `scrobble`, `star`), dem **Cover Art Archive** (hochauflösende Cover per MusicBrainz-ID) und **LRCLIB** (offener Songtext-Fallback).

Radio nutzt den offenen **[Radio-Browser](https://www.radio-browser.info/)**-Katalog (`/json/stations/search`, Spiegel-Fallback über `de1`/`at1`/`nl1`) und spielt eigene Stream-URLs direkt; die laufende Sendung kommt aus den ICY-Metadaten des Streams.

## Über dieses Projekt
Mär ist mit Unterstützung von KI entwickelt.
