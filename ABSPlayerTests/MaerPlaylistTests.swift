// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Paket 1: die Regeln der Mär-Playlists — die Grenze, die Rückmeldungen und
/// der Grundsatz „was in die Warteschlange darf, darf in eine Playlist".
@MainActor
struct MaerPlaylistTests {
    private func fresh() -> MaerPlaylists {
        let store = MaerPlaylists.shared
        for list in store.playlists { store.delete(playlistId: list.id) }
        return store
    }

    @Test("die Grenze ist die VORHANDENE canEnqueue-Regel, keine zweite")
    func gateIsTheQueueRule() {
        let store = fresh()
        let list = store.create(name: "Test")
        // Radio ist ein endloser Strom — kein Listeneintrag (Entscheid F3).
        #expect(store.add(itemId: "radio:swr2", to: list.id) == .notQueueable)
        #expect(!PlayQueue.canEnqueue("radio:swr2"))
        // Katalog-Kennungen dürfen — das ist der ganze Zweck des Typs.
        #expect(store.add(itemId: "jam:1886432", to: list.id) == .added)
        #expect(store.add(itemId: "lva:OTRR_Gunsmoke_Singles", to: list.id) == .added)
        store.delete(playlistId: list.id)
    }

    // MARK: - P4: der Titel-Schnappschuss scheitert nicht mehr still

    @Test("bei kaltem Katalog-Cache trägt die Fläche den Titel bei")
    func snapshotComesFromTheAddingSurface() {
        let store = fresh()
        let list = store.create(name: "Test")
        // Genau the owner's Fall: der Cache kennt die Katalog-Kennung nicht
        // (kalter Start), die Fläche hatte den Namen aber auf dem Schirm.
        #expect(store.add(itemId: "jam:1886432", to: list.id,
                          knownTitle: "Sonata No. 3") == .added)
        #expect(store.playlist(id: list.id)?.titles["jam:1886432"] == "Sonata No. 3")
        // Ohne Mitgabe bleibt der Schnappschuss leer (und wird geloggt) —
        // das ist der Zustand, den die Zeile per Detail-Abruf heilt.
        #expect(store.add(itemId: "jam:99", to: list.id) == .added)
        #expect(store.playlist(id: list.id)?.titles["jam:99"] == nil)
        store.delete(playlistId: list.id)
    }

    @Test("ein Platzhalter darf NIE Schnappschuss werden")
    func placeholderIsNeverPersisted() {
        // Der Zaun, vor dem der alte Kommentar zu Recht warnte — jetzt an
        // einer prüfbaren Stelle statt als Absicht.
        #expect(MaerPlaylists.usableTitle("Unknown Title", for: "jam:1") == nil)
        // Synchronisierte Daten: auch die Fassung eines fremdsprachigen
        // Geräts darf nicht durchrutschen.
        #expect(MaerPlaylists.usableTitle(String(localized: "Unknown Title"), for: "jam:1") == nil)
        #expect(MaerPlaylists.usableTitle("jam:1", for: "jam:1") == nil)
        #expect(MaerPlaylists.usableTitle("   ", for: "jam:1") == nil)
        #expect(MaerPlaylists.usableTitle(nil, for: "jam:1") == nil)
        #expect(MaerPlaylists.usableTitle("  Echter Titel ", for: "jam:1") == "Echter Titel")
        // Und er kommt auch über die Mitgabe nicht in die geteilten Daten.
        let store = fresh()
        let list = store.create(name: "Test")
        #expect(store.add(itemId: "jam:7", to: list.id, knownTitle: "Unknown Title") == .added)
        #expect(store.playlist(id: list.id)?.titles["jam:7"] == nil)
        store.delete(playlistId: list.id)
    }

    @Test("die Mehrfach-Zugabe reicht die Titel je Kennung durch")
    func multiAddCarriesTitles() {
        let store = fresh()
        let list = store.create(name: "Test")
        #expect(store.add(itemIds: ["jam:1", "jam:2"], to: list.id,
                          knownTitles: ["jam:1": "Erster", "jam:2": "Zweiter"]) == .added)
        #expect(store.playlist(id: list.id)?.titles["jam:2"] == "Zweiter")
        store.delete(playlistId: list.id)
    }

    @Test("eine Liste mischt Namensräume — das ist ihr Zweck")
    func mixesNamespaces() {
        let store = fresh()
        let list = store.create(name: "Gemischt",
                                itemIds: ["jam:1", "lva:x", "lv:176", "sub:song:abc"])
        #expect(store.playlist(id: list.id)?.itemIds.count == 4)
        store.delete(playlistId: list.id)
    }

    @Test("doppelt hinzufügen meldet sich, statt still zu wiederholen")
    func duplicateIsReported() {
        let store = fresh()
        let list = store.create(name: "Test")
        #expect(store.add(itemId: "jam:7", to: list.id) == .added)
        #expect(store.add(itemId: "jam:7", to: list.id) == .alreadyThere)
        #expect(store.playlist(id: list.id)?.itemIds.count == 1)
        store.delete(playlistId: list.id)
    }

    @Test("jedes Ergebnis bekommt einen Satz — außer dem Erfolg")
    @MainActor
    func everyOutcomeSpeaks() {
        // Regel 3: Erfolg braucht keine Meldung, alles andere schon.
        #expect(PlaylistPresenter.text(for: .added, listName: "L") == nil)
        #expect(PlaylistPresenter.text(for: .alreadyThere, listName: "L") != nil)
        #expect(PlaylistPresenter.text(for: .limitReached(limit: 5000), listName: "L") != nil)
        #expect(PlaylistPresenter.text(for: .notQueueable, listName: "L") != nil)
        // Die Grenz-Meldung nennt die ZAHL, sonst ist sie nicht handelbar.
        #expect(PlaylistPresenter.text(for: .limitReached(limit: 5000), listName: "L")?
            .contains("5") == true)
    }

    @Test("das Umsortieren behält alle Einträge")
    func reorderKeepsEverything() {
        let store = fresh()
        let list = store.create(name: "Test", itemIds: ["a1", "b2", "c3", "d4"])
        store.move(playlistId: list.id, from: IndexSet(integer: 0), to: 3)
        let ids = store.playlist(id: list.id)?.itemIds ?? []
        #expect(ids.count == 4)
        #expect(Set(ids) == ["a1", "b2", "c3", "d4"])
        #expect(ids.first != "a1", "der bewegte Eintrag steht nicht mehr vorn")
        store.delete(playlistId: list.id)
    }
}
#endif

// MARK: - f208790: Playlisten sind SONGS

@MainActor
struct PlaylistSongSemanticsTests {
    @Test("ein WERK bleibt EIN Eintrag, ein Song bleibt er selbst")
    func worksAndSongsPassThrough() async {
        // Ohne bekannte Form (kein Detail gesehen) wird NICHT geraten — der
        // Eintrag bleibt, wie er ist. Und eine Song-Kennung ist bereits ein
        // Titel, sie wird nie noch einmal expandiert.
        let songId = CatalogSongID.make(album: "ia:some-album", index: 2)
        let out = await PlaylistPresenter.expandedForDevice([songId])
        #expect(out.ids == [songId])
        // Nicht-Katalog-Kennungen laufen unveraendert durch.
        let server = await PlaylistPresenter.expandedForDevice(["sub:song:1", "lv:176"])
        #expect(server.ids.contains("sub:song:1"))
    }

    // MARK: - Die Regel selbst (rein, ohne Anbieter)

    @Test("ein Server-ALBUM ist Titel, ein Server-Song ist einer")
    func serverContainersExpand() {
        // Der eigentliche Fund: bis hierher fragte nur der Katalog-Pfad nach
        // der Form — ein Server-Album landete als EIN Eintrag in einer
        // Geraeteliste, dieselbe Fehlerklasse einen Namensraum weiter.
        #expect(PlaylistDestination.expansion(for: "sub:album:1", serverKind: .album)
                == .serverContainer)
        #expect(PlaylistDestination.expansion(for: "sub:playlist:1", serverKind: .playlist)
                == .serverContainer)
        #expect(PlaylistDestination.expansion(for: "sub:song:1", serverKind: .song) == .asIs)
    }

    @Test("eine Katalog-Veroeffentlichung fragt die Form, eine Titel-Adresse nicht")
    func catalogReleasesAskTheForm() {
        #expect(PlaylistDestination.expansion(for: "lva:some-release", serverKind: nil)
                == .catalogRelease)
        let songId = CatalogSongID.make(album: "lva:some-release", index: 0)
        #expect(PlaylistDestination.expansion(for: songId, serverKind: nil) == .asIs)
        // Ein Hoerbuch, eine Folge, eine Lesung: EIN Eintrag.
        #expect(PlaylistDestination.expansion(for: "lv:176", serverKind: nil) == .asIs)
        #expect(PlaylistDestination.expansion(for: "rss:abc#1", serverKind: nil) == .asIs)
    }

    @Test("der Server-Ort steht nur mit Server UND nur fuer seine Titel")
    func placesAreHonest() {
        // G8: kein totes Ziel. Ein Katalog-Titel hat auf Navidrome keine
        // Adresse — die Sektion erscheint dann gar nicht.
        #expect(PlaylistDestination.places(serverConfigured: true, allOwnedByServer: true)
                == [.server, .device])
        #expect(PlaylistDestination.places(serverConfigured: true, allOwnedByServer: false)
                == [.device])
        #expect(PlaylistDestination.places(serverConfigured: false, allOwnedByServer: true)
                == [.device])
        // Der Geraete-Ort steht IMMER — jede einreihbare Adresse passt dorthin.
        for server in [true, false] {
            for owned in [true, false] {
                #expect(PlaylistDestination.places(serverConfigured: server,
                                                   allOwnedByServer: owned).contains(.device))
            }
        }
    }
}
