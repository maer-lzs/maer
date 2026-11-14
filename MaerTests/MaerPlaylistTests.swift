// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The rules of the Mär playlists. The limit, the feedback and the
/// principle that everything allowed into the queue is also allowed into a
/// playlist.
@MainActor
struct MaerPlaylistTests {
    /// A store of its own over a database file and a directory of its
    /// own, so no case writes the simulator's real rows.
    private func fresh() -> MaerPlaylists {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playlists-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
    }

    @Test("the limit is the EXISTING canEnqueue rule, not a second one")
    func gateIsTheQueueRule() {
        let store = fresh()
        let list = store.create(name: "Test")
        // Radio is an endless stream. Not a list entry.
        #expect(store.add(itemId: "radio:swr2", to: list.id) == .notQueueable)
        #expect(!PlayQueue.canEnqueue("radio:swr2"))
        // Catalog identifiers are allowed. That is the whole purpose of the type.
        #expect(store.add(itemId: "jam:1886432", to: list.id) == .added)
        #expect(store.add(itemId: "lva:OTRR_Gunsmoke_Singles", to: list.id) == .added)
        store.delete(playlistId: list.id)
    }

    // MARK: - The title snapshot no longer fails silently

    @Test("with a cold catalog cache the surface supplies the title")
    func snapshotComesFromTheAddingSurface() {
        let store = fresh()
        let list = store.create(name: "Test")
        // The measured case: the cache does not know the catalog identifier
        // (cold start), but the surface had the name on screen.
        #expect(store.add(itemId: "jam:1886432", to: list.id,
                          knownTitle: "Sonata No. 3") == .added)
        #expect(store.playlist(id: list.id)?.titles["jam:1886432"] == "Sonata No. 3")
        // Without a supplied title the snapshot stays empty (and is logged).
        // That is the state the row heals by a detail fetch.
        #expect(store.add(itemId: "jam:99", to: list.id) == .added)
        #expect(store.playlist(id: list.id)?.titles["jam:99"] == nil)
        store.delete(playlistId: list.id)
    }

    @Test("a placeholder must NEVER become a snapshot")
    func placeholderIsNeverPersisted() {
        // The fence the old comment rightly warned about. Now at a
        // checkable place instead of an intention.
        #expect(MaerPlaylists.usableTitle("Unknown Title", for: "jam:1") == nil)
        // Synced data: the version of a device in another language must
        // not slip through either.
        #expect(MaerPlaylists.usableTitle(String(localized: "Unknown Title"), for: "jam:1") == nil)
        #expect(MaerPlaylists.usableTitle("jam:1", for: "jam:1") == nil)
        #expect(MaerPlaylists.usableTitle("   ", for: "jam:1") == nil)
        #expect(MaerPlaylists.usableTitle(nil, for: "jam:1") == nil)
        #expect(MaerPlaylists.usableTitle("  Echter Titel ", for: "jam:1") == "Echter Titel")
        // And it does not reach the shared data through the supplied title either.
        let store = fresh()
        let list = store.create(name: "Test")
        #expect(store.add(itemId: "jam:7", to: list.id, knownTitle: "Unknown Title") == .added)
        #expect(store.playlist(id: list.id)?.titles["jam:7"] == nil)
        store.delete(playlistId: list.id)
    }

    @Test("the multiple add passes the titles through per identifier")
    func multiAddCarriesTitles() {
        let store = fresh()
        let list = store.create(name: "Test")
        #expect(store.add(itemIds: ["jam:1", "jam:2"], to: list.id,
                          knownTitles: ["jam:1": "Erster", "jam:2": "Zweiter"]) == .added)
        #expect(store.playlist(id: list.id)?.titles["jam:2"] == "Zweiter")
        store.delete(playlistId: list.id)
    }

    @Test("a list mixes namespaces, which is its purpose")
    func mixesNamespaces() {
        let store = fresh()
        let list = store.create(name: "Gemischt",
                                itemIds: ["jam:1", "lva:x", "lv:176", "sub:song:abc"])
        #expect(store.playlist(id: list.id)?.itemIds.count == 4)
        store.delete(playlistId: list.id)
    }

    @Test("adding twice reports itself instead of repeating silently")
    func duplicateIsReported() {
        let store = fresh()
        let list = store.create(name: "Test")
        #expect(store.add(itemId: "jam:7", to: list.id) == .added)
        #expect(store.add(itemId: "jam:7", to: list.id) == .alreadyThere)
        #expect(store.playlist(id: list.id)?.itemIds.count == 1)
        store.delete(playlistId: list.id)
    }

    @Test("every result gets a sentence, except success")
    @MainActor
    func everyOutcomeSpeaks() {
        // Success needs no message, everything else does.
        #expect(PlaylistPresenter.text(for: .added, listName: "L") == nil)
        #expect(PlaylistPresenter.text(for: .alreadyThere, listName: "L") != nil)
        #expect(PlaylistPresenter.text(for: .limitReached(limit: 5000), listName: "L") != nil)
        #expect(PlaylistPresenter.text(for: .notQueueable, listName: "L") != nil)
        // The limit message names the NUMBER, otherwise it cannot be acted on.
        #expect(PlaylistPresenter.text(for: .limitReached(limit: 5000), listName: "L")?
            .contains("5") == true)
    }

    @Test("reordering keeps all entries")
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

// MARK: - Playlists are SONGS

@MainActor
struct PlaylistSongSemanticsTests {
    @Test("a WORK stays ONE entry, a song stays itself")
    func worksAndSongsPassThrough() async {
        // Without a known shape (no detail seen) there is NO guessing. The
        // entry stays as it is. And a song identifier already is a
        // title, it is never expanded again.
        let songId = CatalogSongID.make(album: "ia:some-album", index: 2)
        let out = await PlaylistPresenter.expandedForDevice([songId])
        #expect(out.ids == [songId])
        // Non-catalog identifiers pass through unchanged.
        let server = await PlaylistPresenter.expandedForDevice(["sub:song:1", "lv:176"])
        #expect(server.ids.contains("sub:song:1"))
    }

    // MARK: - The rule itself (pure, no provider)

    @Test("a server ALBUM is a title, a server song is one")
    func serverContainersExpand() {
        // The actual finding: up to here only the catalog path asked for
        // the shape. A server album ended up as ONE entry in a
        // device list, the same class of error one namespace further.
        #expect(PlaylistDestination.expansion(for: "sub:album:1", serverKind: .album)
                == .serverContainer)
        #expect(PlaylistDestination.expansion(for: "sub:playlist:1", serverKind: .playlist)
                == .serverContainer)
        #expect(PlaylistDestination.expansion(for: "sub:song:1", serverKind: .song) == .asIs)
    }

    @Test("a catalog release asks for the shape, a title address does not")
    func catalogReleasesAskTheForm() {
        #expect(PlaylistDestination.expansion(for: "lva:some-release", serverKind: nil)
                == .catalogRelease)
        let songId = CatalogSongID.make(album: "lva:some-release", index: 0)
        #expect(PlaylistDestination.expansion(for: songId, serverKind: nil) == .asIs)
        // An audiobook, an episode, a reading: ONE entry.
        #expect(PlaylistDestination.expansion(for: "lv:176", serverKind: nil) == .asIs)
        #expect(PlaylistDestination.expansion(for: "rss:abc#1", serverKind: nil) == .asIs)
    }

    @Test("the server place appears only with a server AND only for its titles")
    func placesAreHonest() {
        // No dead target. A catalog title has no address on Navidrome.
        // The section then does not appear at all.
        #expect(PlaylistDestination.places(servers: [.subsonic]) == [.server, .device])
        #expect(PlaylistDestination.places(servers: [.subsonic, .jellyfin]) == [.server, .device])
        #expect(PlaylistDestination.places(servers: []) == [.device])
        // The device place is ALWAYS there. Every queueable address fits it.
        for servers: [MusicSourceRule.Server] in [[], [.subsonic], [.jellyfin], [.subsonic, .jellyfin]] {
            #expect(PlaylistDestination.places(servers: servers).contains(.device))
        }
    }

    @Test("a server playlist gets only titles of its server, mixed ones only the device")
    func serversForEntries() {
        typealias S = MusicSourceRule.Server
        let both: [S] = [.subsonic, .jellyfin]
        // (active, owner per entry) -> servers to choose from
        let table: [([S], [S?], [S])] = [
            (both, [], both),                              // empty new list: every active server, „Wo?"
            (both, [.jellyfin, .jellyfin], [.jellyfin]),   // titles of ONE server: that one
            (both, [.subsonic], [.subsonic]),
            (both, [.subsonic, .jellyfin], []),            // two servers: only the device
            (both, [.subsonic, nil], []),                  // a catalog title among them: only the device
            ([.subsonic], [.subsonic], [.subsonic]),       // ONE server: as before
            ([.subsonic], [], [.subsonic]),
            ([.subsonic], [.jellyfin], []),                // the server is not active
            ([], [], []),
        ]
        for (active, owners, expected) in table {
            #expect(PlaylistDestination.servers(active: active, owners: owners) == expected,
                    "aktiv \(active), Besitzer \(owners)")
        }
        #expect(PlaylistDestination.mixesServers([.subsonic, .jellyfin]))
        #expect(!PlaylistDestination.mixesServers([.subsonic, nil]), "ein Katalog-Titel ist kein zweiter Server")
        #expect(MusicSourceRule.owner("jf:song:1") == .jellyfin)
        #expect(MusicSourceRule.owner("sub:song:1") == .subsonic)
        #expect(MusicSourceRule.owner("lv:176") == nil)
    }

    @Test("preselected is the server whose playlist was changed last")
    func lastChangedServer() {
        #expect(PlaylistDestination.lastChanged([(.subsonic, 10), (.jellyfin, 30), (.subsonic, 20)]) == .jellyfin)
        #expect(PlaylistDestination.lastChanged([(.subsonic, nil), (.jellyfin, nil)]) == nil)
        #expect(PlaylistDestination.lastChanged([(.subsonic, nil), (.jellyfin, 5)]) == .jellyfin)
        #expect(PlaylistDestination.lastChanged([]) == nil)
    }

    /// The sentences of the add sheet name the music server by its product,
    /// never its address; an unknown one is "your music server".
    @Test("the sentences under the Mär playlists name the server by its product name, an unknown one is called your music server", .needsTheSources)
    func theSheetNamesTheServerByProduct() throws {
        #expect(MusicSourceName.product(.subsonic, reportedType: "navidrome") == "Navidrome")
        #expect(MusicSourceName.product(.subsonic, reportedType: "Navidrome") == "Navidrome")
        #expect(MusicSourceName.product(.subsonic, reportedType: "gonic") == "gonic")
        #expect(MusicSourceName.product(.subsonic, reportedType: "koel") == "Koel", "a measured type is missing")
        #expect(MusicSourceName.product(.subsonic, reportedType: " funkwhale ") == "Funkwhale")
        #expect(MusicSourceName.product(.subsonic, reportedType: "some-new-server") == nil, "an unknown type must not be shown raw")
        #expect(MusicSourceName.product(.subsonic, reportedType: nil) == nil, "a plain Subsonic server must not get a name")
        #expect(MusicSourceName.product(.jellyfin, reportedType: nil) == "Jellyfin")
        #expect(MusicSourceName.product(nil, reportedType: "navidrome") == nil)
        // One place answers the name of a music server: the table lives
        // beside the capsule's name, and no second answer comes back.
        let sources = ProjectFileIntegrityTests.sourceTexts()
        let tables = sources.filter { $0.text.contains("\"navidrome\": \"Navidrome\"") }.map(\.name)
        #expect(tables == ["MusicSourceName.swift"], "the table of known servers stands elsewhere or twice: \(tables)")
        #expect(!sources.contains { $0.text.contains("enum MusicServerName") }, "a second answer to the server's name came back")
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        func german(_ key: String) -> String? {
            ((strings[key]?["localizations"] as? [String: Any])?["de"] as? [String: Any])
                .flatMap { $0["stringUnit"] as? [String: Any] }?["value"] as? String
        }
        #expect(german("Mär playlists stay on your devices and can mix everything: music from %@, open catalogs and local files.")
                == "Mär-Playlists bleiben auf deinen Geräten und dürfen alles mischen: Musik von %@, offene Kataloge und lokale Dateien.")
        #expect(german("Mär playlists stay on your devices and can mix everything: music from your music server, open catalogs and local files.")?
                    .contains("deinem Musikserver") == true)
        #expect(german("These entries can only go into a Mär playlist: %@ cannot reference a catalog or local address.")?
                    .hasPrefix("Diese Einträge passen nur in eine Mär-Playlist: %@") == true)
        #expect(german("These entries can only go into a Mär playlist: your music server cannot reference a catalog or local address.")?
                    .contains("Dein Musikserver") == true)
        let old = strings.keys.filter { $0.contains("device playlist") || $0.hasPrefix("Device playlists") }
        #expect(old.isEmpty, "the old sentences still stand: \(old)")
        #expect(german("These entries only fit into a Mär playlist.") == "Diese Einträge passen nur in eine Mär-Playlist.")
    }

    /// With no music server set up, the sentence under "Mär playlists"
    /// names none: "your music server" blamed a server that is not there.
    @Test("without a music server the sentence under the Mär playlists names no server")
    func withoutAMusicServerTheSentenceNamesNone() {
        // Compared with the catalog's own sentences, in whatever language the
        // test host runs.
        let unnamed = String(localized: "These entries can only go into a Mär playlist: your music server cannot reference a catalog or local address.")
        let none = PlaylistOnlyMaerSentence.text(namedServer: nil, anyMusicServer: false)
        #expect(none == String(localized: "These entries only fit into a Mär playlist."), "a server is named although none is set up")
        #expect(PlaylistOnlyMaerSentence.text(namedServer: nil, anyMusicServer: true) == unnamed,
                "with a server of unknown type the sentence still says why")
        #expect(PlaylistOnlyMaerSentence.text(namedServer: "gonic", anyMusicServer: true).contains("gonic"))
    }

    /// The footer of a Mär playlist's page names no server's music when no
    /// music server is set up.
    @Test("without a music server the footer sentence of a Mär playlist names no server's music", .needsTheSources)
    func withoutAMusicServerTheFooterNamesNone() throws {
        let withoutServer = "Playlists on your devices mix music from open catalogs and your own files. They stay on your devices."
        #expect(MaerPlaylistFooter.text(anyMusicServer: false, routine: false) == String(localized: String.LocalizationValue(withoutServer)))
        let withServer = "Playlists on your devices mix music from your server, from open catalogs and your own files. They stay on your devices."
        #expect(MaerPlaylistFooter.text(anyMusicServer: true, routine: false) == String(localized: String.LocalizationValue(withServer)))
        // A routine mixes no music; it says what it does, with a server or without.
        let routine = "Routines on your devices pick their episodes when they start. They stay on your devices."
        for server in [false, true] {
            #expect(MaerPlaylistFooter.text(anyMusicServer: server, routine: true) == String(localized: String.LocalizationValue(routine)))
        }
        // The German sentences, read from the built catalogue.
        let german = try #require(Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        #expect(german.localizedString(forKey: withServer, value: nil, table: nil)
                == "Playlists auf deinen Geräten mischen Musik von deinem Server, aus offenen Katalogen und eigene Dateien. Sie bleiben auf deinen Geräten.")
        #expect(german.localizedString(forKey: withoutServer, value: nil, table: nil)
                == "Playlists auf deinen Geräten mischen Musik aus offenen Katalogen und eigene Dateien. Sie bleiben auf deinen Geräten.")
        #expect(german.localizedString(forKey: routine, value: nil, table: nil)
                == "Routinen auf deinen Geräten wählen ihre Folgen, wenn sie starten. Sie bleiben auf deinen Geräten.")
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/MusicLibraryPages.swift"), encoding: .utf8))
        #expect(page.contains("MaerPlaylistFooter.text(anyMusicServer:"), "the page writes its own footer again")
        #expect(FetchAnswerTests.squeezed(page).contains("routine: playlist.isRoutine))"), "the page names its kind")
        // A rule this version cannot read: the one row the reason reaches.
        let unread = "A routine rule this version cannot read: the routine starts without it"
        #expect(MaerPlaylistPage.reasonText(.routineRule) == String(localized: String.LocalizationValue(unread)))
        #expect(german.localizedString(forKey: unread, value: nil, table: nil)
                == "Eine Regel, die diese Version nicht lesen kann: die Routine startet ohne sie")
    }
}
