# Mär: Aufbau der Quellen

Zurück zur [README](../README.de.md) · [English](architecture.md)

## Aufbau der Quellen

Der Baum unten ist eine Auswahl, nicht das ganze Repository (`Sources/` hält mehrere hundert Dateien; `tools/` gehört nicht zum Xcode-Projekt, und der Sync-Dienst hat sein eigenes Repository). Er nennt die Schichten, die die App heute tragen; jede Zeile beschreibt die Datei, die sie nennt.

```text
Sources/
├── MaerApp.swift                   Einstiegspunkt + AppDelegate für Hintergrund-Download-Ereignisse;
│                                   wartet auf jede Zeilen-Schreibkette und schreibt die Datenbank
│                                   beim Wechsel in den Hintergrund und beim Beenden fest
├── AppSession.swift                Prozessweite Sitzung (Player-Koordinator, Bibliothek, Provider;
│                                   geteilt mit CarPlay)
├── AppShortcuts.swift              Siri App Intents (Weiterhören, ein Buch, eine Routine abspielen,
│                                   die Audio-Domäne von iOS 27 und Spotlight; Bücher aus den Bibliothekszeilen)
├── Storage/                        Die eine Datenbankdatei (maer.sqlite) und jeder Zeilen-Speicher
│   ├── MaerDatabase.swift          Die eine Datei und die eine Verbindung; Festschreiben beim Gehen
│   ├── SQLiteConnection.swift      Actor über das System-SQLite3, eine Anweisung nach der anderen, WAL
│   ├── SQLiteStatements.swift      Die Anweisungs-Mechanik, die beide Verbindungen teilen
│   ├── SQLiteReader.swift          Nur lesender Leser für den synchronen Start eines Speichers
│   ├── KeyedRowStore.swift         Ein Wörterbuch als Zeilen (Schlüssel + JSON), schreibt Unterschiede
│   ├── RowChain.swift              Die eine Schreibkette eines Zeilen-Speichers, vor dem Festschreiben abgewartet
│   ├── RowKeeper.swift             Startlesen der Zeilen eines Speichers und seine serielle Schreibkette
│   ├── RowBase.swift               Pur: was ein Speicher vor einem Schrieb über seine Zeilen weiß
│   ├── OwnerMark.swift             Welchem Konto die Zeilen einer Familie gehören, mit ihnen geschrieben
│   ├── RestingShelf.swift          Wo die Zeilen einer Familie ruhen, während ein anderes Konto das Gerät hält
│   ├── ShelfFollower.swift         Der eine Weg, auf dem eine Familie dem Konto durch die Ablage folgt
│   ├── CarrierRows.swift           Was die Träger zwischen zwei Runden halten, als Zeilen (Abbilder,
│   │                               Warteschlangen, Stempel der Wahlen, Dokumente), Sprungverlauf und Offline-Lesezeichen je Buch
│   ├── PodcastRowStore.swift       Sendungen und Folgen als Zeilen
│   ├── LibraryRowStore.swift       Bibliotheks-Titel und Fortschritt als Zeilen
│   └── StandStore.swift, StandMirror.swift   Hörstände als Zeilen, gespiegelt aus den Defaults
├── Providers/
│   ├── AudioProvider.swift         Protokoll, das jede Audioquelle erfüllt (Anmeldung, Bibliothek,
│   │                               Suche, Stream, Download, Sync); der Kern sieht nur das
│   ├── ABSProvider.swift           Audiobookshelf als erster Provider
│   ├── LocalProvider.swift         Importierte lokale Audiodateien (kein Server)
│   ├── LocalLibrary.swift          Lokaler Datei-Index (Zeilen) + AVAsset-Metadaten
│   ├── SubsonicProvider.swift      Subsonic/OpenSubsonic-Musik (Navidrome, gonic, Airsonic)
│   ├── JellyfinProvider.swift      Jellyfin-Musik und -Hörbücher (jf:-Namensraum; ein Ordner faltet zu einem Buch)
│   ├── FreeCatalogProvider.swift   Wiedergabe für die offenen Kataloge (LibriVox, archive.org, Jamendo)
│   ├── RadioProvider.swift         Internetradio (radio:-Namensraum), Radio Browser + eigene URLs
│   ├── RSSProvider.swift           Podcasts: RSS-Folgen als Bibliotheks-Titel
│   ├── MaerPlaylists.swift         Mär-Playlisten (Zeilen): der ZWEITE Playlist-Typ, mischt alle Kennungen
│   ├── ABSPodcastProvider.swift    Audiobookshelf-Podcast-Bibliotheken (zuschaltbare Quelle)
│   ├── PodcastSubscriptions.swift  Feed-Speicher (Zeilen) + RSS/Podcasting-2.0-Parser auf XMLParser
│   ├── PodcastSubscriptionSync.swift  Abgeglichenes Spiegeln der Abos lokal ↔ ABS
│   ├── PodcastDirectory.swift      Entdecken über PodcastIndex + iTunes-Charts
│   ├── PodcastRecommendationsStore.swift  Nutzungsbasiertes, thematisches Empfehlungs-Ranking
│   ├── ProviderSearch.swift        SearchableProvider-Fähigkeit + Suche je Quelle
│   ├── PlayQueue.swift             Globale medienübergreifende Als-Nächstes-Warteschlange (eine Zeile)
│   ├── UpNextArrivals.swift        Neue Folgen einer Sendung nach dem Aktualisieren in Als Nächstes
│   ├── PlaybackContext.swift       Der Rest eines Sammlungs-Starts (eine Zeile), nicht die Warteschlange
│   └── PodcastImport.swift         Import aus Apple Podcasts, Overcast, AntennaPod und OPML
├── CarPlay/
│   └── CarPlaySceneDelegate.swift  CarPlay-Tabs (Start + Hörbücher + Podcasts + Musik + Radio) + Now Playing
├── Models/
│   ├── AudiobookshelfModels.swift  Codable-Strukturen für die Audiobookshelf-API
│   ├── SubsonicModels.swift        Codable-Strukturen für die Subsonic/OpenSubsonic-API
│   ├── JellyfinModels.swift, JellyfinBookFold.swift   Jellyfin-Strukturen; pures Falten eines Ordners zu einem Buch
│   ├── RadioModels.swift           Radio-Kern nur mit Foundation (Abbildung, ICY-Parser, Speicher)
│   ├── FreeCatalog*.swift          Die offenen Kataloge: Quellen, Decoder, Rechte-Angaben
│   ├── MediaType.swift             Die vier Medienarten (Hörbücher/Podcasts/Musik/Radio)
│   ├── SyncRules.swift             Pure, getestete Sync-Entscheidungsregeln + Zeitrechnung über mehrere Spuren
│   ├── SyncHistory.swift           Pure Einträge des Sync-Verlaufs + Ringpuffer
│   ├── UserChoiceSync.swift        Der Katalog jeder gespeicherten Wahl und ihrer Sync-Klasse
│   ├── HomeSections.swift          Zusammenführung für den Start-Tab (Aktualität, faires Verzahnen)
│   ├── RediscoverSections.swift    Auswahl für Wiederentdecken (pausiert / ungehört / nächstes der Serie)
│   ├── SearchModels.swift          Typen für Suchergebnisse und Ranking
│   ├── AppStorageKeys.swift        Zentrale UserDefaults-Schlüssel, eine Aktivierungs-Antwort je Quelle
│   ├── SourceMap.swift             Pur: die fünf Bereiche und was jeder braucht (Zustände der Karte)
│   ├── MaerPlaylistMerge.swift     Pur: Zusammenführen je Liste, gerettete Fassung, Grabsteine
│   ├── UpNextAuto.swift            Pur: welche neuen Folgen in Als Nächstes kommen, und wohin
│   ├── ServerHeaderRule.swift      Pur: welche Anfrage die eigenen Header eines Servers trägt, und wo eine Umleitung sie lässt
│   ├── HeardElsewhere.swift        Pur: eine Marke von anderswo, die einen Titel gehört machte
│   ├── SharedLink.swift            Pur: der Link auf maer.fm, was er nennt und was geteilt werden darf
│   ├── ABSSingleSignOn.swift, ABSSignInMethods.swift   Pur: die Einmalanmeldung bei Audiobookshelf
│   │                               (Start, Rückkehr, Tausch) und die Wege, die ein Server anbietet
│   └── PodcastAutoDownloadRules.swift  Pur: was der automatische Download aufräumen darf
├── Networking/
│   ├── APIClient.swift             HTTP-Aufrufe an Audiobookshelf
│   ├── ABSSSOFlow.swift            Die Einmalanmeldung im Anmeldefenster des Systems
│   ├── AppUserAgent.swift          DIE eine Kennung, mit der sich die App fremden Servern zeigt
│   ├── StandCarrier.swift, ClaimCarrier.swift, StatsCarrier.swift,
│   │   PlaylistCarrier.swift, ChoiceCarrier.swift
│   │                               Die Träger-Nähte: jede mit einem Schlüsselwert-, einem CloudKit- und
│   │                               einem Sync-Dienst-Träger dahinter; die Läufer kennen keinen davon
│   ├── CloudZoneDatabase.swift, CloudStandDatabase.swift, CloudKit*Carrier.swift
│   │                               Die private Datenbank von iCloud: eine Zone je Datensatztyp
│   ├── MaerSyncClient.swift, MaerSyncCarriers.swift, MaerSyncSignIn.swift
│   │                               Der Mär-Sync-Dienst: Adresse und Token, eine Sitzung für
│   │                               sechs Dokumentarten, die Anmeldung, die einen Beweis sendet, nie das Passwort
│   ├── PodcastCloudSync.swift      Läufer der Hörstände über deine Geräte (über einen Träger)
│   ├── PlaybackClaimSync.swift     Läufer der Markierung „läuft auf einem anderen Gerät“ (über einen Träger)
│   ├── UserChoiceCloudSync.swift   Läufer der reisenden Wahlen (über einen Träger)
│   ├── MaerPlaylistCloudSync.swift Läufer der Mär-Playlisten über deine Geräte (über einen Träger)
│   ├── KeychainStore.swift         Sicherer Speicher für Server-URLs und Tokens
│   ├── DownloadManager.swift       Mehrspur-Offline-Downloads; die Download-Marken sind Zeilen
│   ├── FileDownloader.swift        Gemeinsamer Hintergrund-Download über URLSession mit Fortschritt
│   ├── ImageCache.swift, Artwork.swift   Cover-Cache und DIE eine Tür, durch die jedes Cover geht
│   ├── SubsonicClient.swift        Subsonic/OpenSubsonic-API (Token+Salz-Anmeldung, Streaming, Songtexte)
│   ├── JellyfinClient.swift        Jellyfin-API (Authorization-Kopf, ApiKey an Medien-Links)
│   ├── PinchflatClient.swift       Pinchflat: die Kanalliste als OPML-Spiegel, die Feeds laufen über RSS
│   ├── ServerHeaders.swift         Die eigenen Header eines Servers im iCloud-Schlüsselbund, gesetzt an den vier Wegen nach außen
│   ├── SignInStream.swift          Ein Stream mit Anmeldung wird am Ende seiner Umleitungen gefragt
│   ├── CoverArtArchive.swift       Hochaufgelöste Album-Cover über die MusicBrainz-ID (gedrosselt)
│   ├── RadioBrowserClient.swift    Client für den Radio-Browser-Katalog (Rückfall über Spiegelserver)
│   ├── SyncHistoryStore.swift      Sync-Verlauf (Zeilen) + „zuletzt geprüft“ je Dienst
│   ├── NetworkMonitor.swift        Laufende Beobachtung der Verbindung (automatisches Wiederverbinden)
│   ├── NetworkStatus.swift         Einmalige WLAN-Prüfung und gemeinsame Erkennung von Offline-Fehlern
│   ├── BookmarkQueue.swift         Offline-Warteschlange + Cache für Anlegen/Löschen von Lesezeichen
│   ├── SyncQueue.swift             Warteschlange für gescheiterte Fortschritts-Meldungen (Zeilen, stehen,
│   │                               bevor der Aufruf zurückkehrt; Speicher und API hinter Protokollen für Tests)
│   ├── Retry.swift                 Wiederholen mit Abstand bei vorübergehenden Netzfehlern
│   ├── URLSession+Maer.swift       Gemeinsame Sitzung mit vernünftigen Fristen für Anfrage und Ressource
│   ├── GPodderClient.swift         Client für die gpodder/mygpo-API (Anmeldung, Geräte, Abos, Folgen)
│   ├── GPodderSync.swift           Dreiseitiger Abgleich der gpodder-Abos + Abspiel-Aktionen
│   ├── PodcastFeedAuth.swift       HTTP-Basic-Auth je Feed für Premium-Feeds (Schlüsselbund)
│   ├── PodcastRefreshService.swift Hintergrund-Aktualisierung der Feeds + Benachrichtigungen über neue Folgen
│   └── PodcastServerSave.swift     Verzögertes Speichern gestreamter Feed-Folgen auf dem Server
├── ViewModels/
│   ├── AuthViewModel.swift         Logik des Einrichtungsbildschirms
│   ├── SharedLinkOpener.swift      Was ein Link auf maer.fm in der App öffnet (eine Seite, nie Wiedergabe)
│   ├── GlobalSearchModel.swift, SearchDoor.swift   Suche über alle Quellen und ihre eine Tür
│   ├── LibraryViewModel.swift      Lädt Buchliste und Fortschritt, Sortierung, Serien-Gruppen,
│   │                               Offline-Cache als Zeilen
│   ├── PlayerCoordinator.swift     Hält die aktive Sitzung über die Navigation am Leben,
│   │                               offline-bewusst, Grundlage der Mini-Leiste
│   ├── StreamPlanner.swift         Wo Streams mit Server-Headern oder einer Anmeldung enden: die erste
│   │                               Spur vor dem Start, dann die laufende und die nächsten zwei
│   ├── PlayerViewModel.swift       AVQueuePlayer, Mehrspur-Warteschlange, Spulen/Springen, Kapitel
│   ├── PlayerViewModel+Sync.swift  Sync-Vorgehen: Zeitgeber, Schutz vor Wiedereintritt, Konflikte, Abgleich
│   ├── PlayerViewModel+SleepTimer.swift   Schlaf-Zeitgeber samt Ausblenden der Lautstärke
│   ├── PlayerViewModel+NowPlaying.swift   Befehle vom Sperrbildschirm, Now-Playing-Angaben, Cover
│   └── AppHousekeeping.swift       Die Aufgaben bei Start und Wiederaufnahme, in einer Reihenfolge
└── Views/
    ├── SetupView.swift             Erster Bildschirm: die Karte der Bereiche + Start ohne
    │                               Server; hält ABSLoginForm/ABSLoginPage (die EINE
    │                               Audiobookshelf-Anmeldung, auch hinter „Verbinden“)
    ├── SourceMapCard.swift         DIE Karte der Bereiche: erster Bildschirm UND die Quellen-
    │                               Übersicht in den Einstellungen, dazu SourceAreaPage
    ├── SettingsView.swift          Einstellungen für Wiedergabe, Darstellung, Speicher, Sync, Server
    ├── MaerSyncSettingsView.swift  Einstellungen, Sync: der Mär-Sync-Dienst (Anmelden, Prüfen, Ablehnungen)
    ├── SourcesSettingsView.swift, RowsSettingsView.swift   Welche Quellen und Reihen die Tabs zeigen
    ├── StatsView.swift             Hörstatistik
    ├── RootView.swift              Wechselt zwischen Einrichtung und Bibliothek
    ├── LibraryView.swift           Buchliste, Sortieren/Filtern, Abschnitte, adaptives Raster
    ├── HomeView.swift              Medienübergreifender Start-Tab (Weiterhören/Wiederentdecken/Entdecken/Neueste)
    ├── SearchScreen.swift          Globale Suche als ganze Seite (Bereichsleiste, Stöber-Deck, Katalog)
    ├── FullPlayerOverlay.swift     Ziehbares Liquid-Glass-Blatt, das den vollen Player trägt
    ├── DriveMode.swift, DriveModeView.swift   Fahrmodus: Player mit großen Knöpfen, automatischer Einstieg
    ├── SeriesStackCell.swift       Serien-Stapel-Kachel (aufgefächerte Cover + Anzahl-Badge)
    ├── BookDetailScreen.swift      Buchseite, Download, als gehört markieren, Play/Pause
    ├── BookCoverView.swift         Cover mit Fortschrittsbalken und Status-Badges, in vielen Ansichten genutzt
    ├── BookGridComponents.swift    Gemeinsame Raster-Zelle + Kontextmenü, Seiten für Autor/Genre
    ├── BookmarksSheet.swift        Lesezeichen-Blatt im Player (Liste, Anlegen, Löschen)
    ├── CachedAsyncImage.swift      Ersatz für AsyncImage auf dem ImageCache
    ├── MiniPlayerBar.swift         Stehende schwebende Glas-Mini-Leiste
    ├── FloatingSearchButton.swift  Schwebender Glas-Knopf, der die Suche öffnet
    ├── AdaptiveGlassBackground.swift  Gemeinsamer Liquid-Glass-Stil mit Material-Rückfall
    ├── AirPlayButton.swift         Hülle um die AirPlay-Routenwahl
    ├── PlayerScreen.swift          Voller Player, zeigt die Sitzung des Koordinators
    ├── PlayerView.swift            Player-Oberfläche im Audible-Stil
    ├── CoverColorLoader.swift      Holt eine Akzentfarbe aus dem Cover
    ├── ChapterListView.swift       Kapitelliste als Blatt
    ├── Haptics.swift               Kleiner Helfer für haptisches Feedback
    ├── MediaTabBar.swift           Wähler der Medienart Start/Hörbücher/Podcasts/Musik/Radio
    ├── MediaTile.swift             Gemeinsame Raster-Kachel (Start, neueste Folgen, Empfehlungen)
    ├── MediaRowContent.swift       Gemeinsame Listenzeile (Podcast-Folgen, Bücher, Sender)
    ├── SyncHistoryView.swift       Einstellungen: Sync-Verlauf („zuletzt geprüft“ + Änderungsring)
    ├── ABSSourceView.swift         Quellenseite Audiobookshelf (Zugang, Sync)
    ├── SubsonicSourceView.swift    Quellenseite Musik (Server, Zugangsdaten, Sync)
    ├── JellyfinSourceView.swift    Quellenseite Jellyfin
    ├── RadioSourceView.swift       Quellenseite Radio (Einschalten, eigene Stream-URLs)
    ├── FreeAudiobooksPage.swift, CatalogSourcePage.swift   Die Seiten der offenen Kataloge
    ├── SharedLinkButton.swift      Der Teilen-Knopf und die Vorschau im Teilen-Blatt mit dem Cover
    ├── PodcastsView.swift          Podcast-Start (Weiterhören, Empfehlungen, Warteschlange, Regale)
    ├── PodcastSourceView.swift     Podcasts hinzufügen/importieren und Abo-Quellen wählen
    ├── Podcasts/                   Sendung, Folge, Warteschlange, Entdecken, Einstellungen je Sendung, Karten
    ├── Music/                      Musik-Start, Album, Künstler, Playlisten, Songtext-Panel
    └── Radio/                      Radio-Tab, Senderzeilen, gemeinsames Radio-Bild
```

**Hinweis zur Architektur der Mini-Leiste:** `PlayerCoordinator` lebt in `AppSession` (prozessweit, geteilt mit CarPlay) und übersteht die Navigation. Die Wiedergabe stoppt nicht, wenn der Player-Bildschirm verlassen oder die Mini-Leiste kurz ausgeblendet wird; sie stoppt nur, wenn ausdrücklich ein anderes Buch geöffnet wird.
