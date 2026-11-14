// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// One rule answers which music server serves the device and which serves
/// one item. With one active music source the two answers are the same, so
/// sending a single-item question to the door changes nothing there; only
/// with two does the item's own server win.
struct MusicSourceRuleTests {
    static let ids = ["jf:album:1", "jf:artist:2", "jf:song:3", "sub:album:1", "sub:artist:2",
                      "sub:song:3", "maer-playlist-42", ""]

    @Test("with ONE active music source the door answers per entry the same source as the device")
    func withOneSourceTheDoorAnswersTheDevice() {
        for (subsonic, jellyfin) in [(true, false), (false, true)] {
            let device = MusicSourceRule.device(subsonicServesMusic: subsonic, jellyfinServesMusic: jellyfin)
            // With one server set up, every item it hands out carries its own
            // namespace, or none at all.
            let own = device == .jellyfin ? "jf:" : "sub:"
            for id in Self.ids where id.hasPrefix(own) || !(id.hasPrefix("jf:") || id.hasPrefix("sub:")) {
                #expect(MusicSourceRule.item(id, device: device) == device, "\(id) bei \(device)")
            }
        }
        #expect(MusicSourceRule.device(subsonicServesMusic: false, jellyfinServesMusic: false) == .subsonic,
                "ohne Musikquelle wie bisher")
    }

    @Test("with TWO sources an entry's own server wins")
    func withTwoSourcesTheItemsServerWins() {
        let device = MusicSourceRule.device(subsonicServesMusic: true, jellyfinServesMusic: true)
        #expect(device == .subsonic, "das Geraet: vorerst Subsonic, die Frage von F5b")
        #expect(MusicSourceRule.item("jf:artist:2", device: device) == .jellyfin)
        #expect(MusicSourceRule.item("sub:artist:2", device: device) == .subsonic)
        #expect(MusicSourceRule.item("maer-playlist-42", device: device) == .subsonic,
                "ohne Namensraum antwortet das Geraet")
    }

    /// The search target keeps the hit's item id, so the page that opens it
    /// resolves the artist at the hit's own server.
    @Test("an artist hit carries its identifier all the way to the target")
    func anArtistHitCarriesItsIdToTheTarget() {
        let hit = SearchResult(id: "jf:artist:9", kind: .artist, title: "A", subtitle: nil, coverURL: nil)
        var asked: [String] = []
        let lookups = SearchLookups(item: { _ in false }, catalogHasParts: { _ in false },
                                    catalogKnows: { _ in false },
                                    artistId: { $0.hasPrefix("jf:artist:") ? "9" : nil },
                                    artistKnown: { asked.append($0); return true })
        #expect(SearchRouting.target(for: hit, lookups: lookups) == .artist(itemId: "jf:artist:9"))
        #expect(asked == ["jf:artist:9"], "gefragt wird mit der Kennung des Treffers, nicht mit der rohen Nummer")
        let unknown = SearchLookups(item: { _ in false }, catalogHasParts: { _ in false },
                                    catalogKnows: { _ in false }, artistId: { _ in "9" },
                                    artistKnown: { _ in false })
        #expect(SearchRouting.target(for: hit, lookups: unknown) == .unavailable)
    }

    /// The single-item questions ask the door, whoever the receiver.
    @Test("player artist and search target ask the door per entry", .needsTheSources)
    func thePlayerAndTheSearchTargetAskTheDoor() throws {
        func code(_ path: String) throws -> String {
            try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8)
        }
        let player = try code("Sources/Views/PlayerView.swift")
        #expect(player.contains("AppSession.shared.musicProvider(for: id).allArtists()"))
        let door = try #require(functionBody(of: "static func target(for result: SearchResult) -> SearchTarget {",
                                             in: try code("Sources/ViewModels/SearchDoor.swift")))
        #expect(MusicProviderDoorFenceTests.deviceQuestions(in: door) == 0,
                "das Such-Ziel fragt wieder das Geraet")
        let library = try #require(functionBody(of: "private func openSearchResult(_ result: SearchResult) {",
                                                in: try code("Sources/Views/LibraryView.swift")))
        #expect(MusicProviderDoorFenceTests.deviceQuestions(in: library) == 0,
                "die Treffer-Seite fragt wieder das Geraet")
    }

    // MARK: One source or both

    @Test("who serves the lists: one source or both")
    func servingTable() {
        #expect(MusicSourceRule.serving(subsonicServesMusic: true, jellyfinServesMusic: false) == .one(.subsonic))
        #expect(MusicSourceRule.serving(subsonicServesMusic: false, jellyfinServesMusic: true) == .one(.jellyfin))
        #expect(MusicSourceRule.serving(subsonicServesMusic: false, jellyfinServesMusic: false) == .one(.subsonic),
                "ohne Quelle wie bisher Subsonic")
        #expect(MusicSourceRule.serving(subsonicServesMusic: true, jellyfinServesMusic: true) == .both)
    }

    @Test("with ONE source the answer is exactly the provider from before")
    @MainActor
    func withOneSourceItIsTheSameObject() {
        let session = AppSession.shared
        #expect(session.musicProvider(serving: .one(.subsonic)) === SubsonicProvider.shared)
        #expect(session.musicProvider(serving: .one(.jellyfin)) === JellyfinProvider.shared)
    }

    // MARK: Artists and playlists carry their source

    @Test("artists and playlists carry their identifier with namespace, and the door finds their server")
    func artistsAndPlaylistsCarryTheirSource() throws {
        // Decoded from the wire, the way each provider receives them.
        func wire<T: Decodable>(_ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
        let subArtist = SubsonicProvider.domainArtist(try wire(#"{"id":"7","name":"A","albumCount":1}"#))
        let jfArtist = JellyfinProvider.domainArtist(try wire(#"{"Id":"7","Name":"A","ChildCount":1}"#))
        #expect(subArtist.id == "7" && jfArtist.id == "7", "die rohe Nummer bleibt, mit ihr wird der Server gefragt")
        #expect(subArtist.itemId == "sub:artist:7" && jfArtist.itemId == "jf:artist:7")
        let subList = SubsonicProvider.domainPlaylist(try wire(#"{"id":"5","name":"P","songCount":1}"#))
        let jfList = JellyfinProvider.domainPlaylist(try wire(#"{"Id":"5","Name":"P","ChildCount":1}"#))
        #expect(subList.itemId == "sub:playlist:5" && jfList.itemId == "jf:playlist:5")
        // Two servers, the same raw number: the door still tells them apart.
        for device in [MusicSourceRule.Server.subsonic, .jellyfin] {
            #expect(MusicSourceRule.item(subArtist.itemId, device: device) == .subsonic)
            #expect(MusicSourceRule.item(jfArtist.itemId, device: device) == .jellyfin)
            #expect(MusicSourceRule.item(subList.itemId, device: device) == .subsonic)
            #expect(MusicSourceRule.item(jfList.itemId, device: device) == .jellyfin)
        }
    }

    @Test("with ONE source the identifier of an artist or a playlist leads to the device's source")
    func withOneSourceTheCarriedIdIsTheDevice() {
        let pairs: [(MusicSourceRule.Server, String, String)] = [
            (.subsonic, SubsonicProvider.itemId(artistId: "1"), SubsonicProvider.itemId(playlistId: "1")),
            (.jellyfin, JellyfinProvider.itemId(artistId: "1"), JellyfinProvider.itemId(playlistId: "1")),
        ]
        for (device, artist, playlist) in pairs {
            #expect(MusicSourceRule.item(artist, device: device) == device)
            #expect(MusicSourceRule.item(playlist, device: device) == device)
        }
    }

    /// Outside the providers nobody builds an artist or playlist id from a
    /// raw number any more: the id travels with the value.
    nonisolated static func rawIdBuilds(in text: String) -> Int {
        text.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//")
                && (trimmed.contains(".itemId(playlistId:") || trimmed.contains(".itemId(artistId:"))
        }.count
    }

    @Test("outside the providers nobody builds an identifier from a raw number", .needsTheSources)
    func noRawIdBuildsOutsideTheProviders() throws {
        let root = SourceTree.root.appendingPathComponent("Sources")
        var read = 0
        var found: [String] = []
        for url in SourceTree.files(under: root) where url.pathExtension == "swift"
            && !url.path.contains("/Sources/Providers/") {
            read += 1
            let count = Self.rawIdBuilds(in: try String(contentsOf: url, encoding: .utf8))
            if count > 0 { found.append("\(url.lastPathComponent): \(count)") }
        }
        #expect(read > 100, "der Zaun hat die Quellen gelesen")
        #expect(found.isEmpty, "eine Kennung aus einer rohen Nummer: \(found)")
        #expect(Self.rawIdBuilds(in: "let id = music.itemId(playlistId: playlist.id)") == 1)
        #expect(Self.rawIdBuilds(in: "id: AppSession.shared.musicProvider.itemId(artistId: a.id)") == 1)
        #expect(Self.rawIdBuilds(in: "// music.itemId(playlistId: x)\nlet id = playlist.itemId") == 0)
    }
}
#endif
