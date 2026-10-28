// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A shuffle whose songs do not come (a music server that does not answer)
/// starts nothing and says so; the server's songs fail with a log line,
/// never a silent empty list.
@MainActor
struct ShuffleEmptyPoolTests {
    @Test("ein leerer Vorrat sagt den Satz der Albumseite, offline nach dem Netz des Geraets")
    func anEmptyPoolSaysWhyByTheDevicesNetwork() async {
        let cases: [(ShufflePool, Bool, String)] = [
            (.unavailable, true, String(localized: "Couldn't load tracks")),
            (.unavailable, false, String(localized: "Not available offline")),
            (.empty, true, String(localized: "No tracks")),
            (.empty, false, String(localized: "No tracks")),
        ]
        for (pool, online, sentence) in cases {
            let coordinator = PlayerCoordinator(provider: MockProvider())
            await ShufflePlayButton.start(pool: { pool }, isOnline: online, coordinator: coordinator)
            #expect(coordinator.loadError == sentence, "\(pool) online=\(online) said \(coordinator.loadError ?? "nothing")")
        }
        #expect(ShufflePlayButton.sentence(for: .unavailable, isOnline: false).1 == .network)
    }

    @Test("ein verschluckter Ausfall heisst nicht leer: Liste in der Hand leer, Abruf ohne Lieder nicht gekommen")
    func aSwallowedFailureIsNotEmpty() throws {
        if case .unavailable = ShufflePool.fetched([]) {} else { Issue.record("a fetch that gave nothing reads as empty") }
        if case .empty = ShufflePool.of([]) {} else { Issue.record("an empty list in hand is not empty") }
        if case .unavailable = ShufflePool.server([], failed: true) {} else { Issue.record("a failed server fetch is not unavailable") }
        if case .empty = ShufflePool.server([], failed: false) {} else { Issue.record("an empty server answer is not empty") }
        // A host the device cannot find while it has a network is a source
        // that did not answer, not offline: the device decides, not the code.
        MusicSongsFailure.log(itemId: "sub:al-witness", URLError(.cannotFindHost))
        #expect(MusicSongsFailure.take("sub:al-witness"))
        #expect(!MusicSongsFailure.take("sub:al-witness"), "the mark is taken once")
        #expect(ShufflePlayButton.sentence(for: .server([], failed: true), isOnline: true).0
                == String(localized: "Couldn't load tracks"))
    }

    @Test("die Wege, die einen Ausfall verschlucken, sagen fetched", .needsTheSources)
    func theSwallowingPathsSayFetched() throws {
        func read(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        #expect(try read("Sources/Views/Music/MusicLibraryPages.swift")
            .contains(".fetched(await AppSession.shared.musicProvider.shuffleLibrarySongItems())"))
        #expect(try read("Sources/Views/CatalogSourcePage.swift").contains("{ .fetched(await albumSongs()) }"))
        #expect(try read("Sources/Views/Music/MusicView.swift")
            .contains("songs: { .fetched(await CatalogShuffleSongs.songs(of: item, albumSongs: albumSongs)) }"))
        #expect(try read("Sources/Views/Music/ShufflePlayButton.swift").contains("@Environment(\\.isOnline) private var isOnline"))
    }

    /// The body of `songItems(forItemId:)` in a provider file.
    static func songItemsBody(_ path: String) throws -> String {
        let source = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        let start = try #require(source.range(of: "func songItems(forItemId itemId: String) async -> [LibraryItem] {"))
        let rest = source[start.upperBound...]
        // The function ends at the first brace on its own indentation.
        let end = try #require(rest.range(of: "\n    }\n")).lowerBound
        return String(rest[..<end])
    }

    @Test("die Lieder eines Musikservers fallen nie still aus", .needsTheSources)
    func serverSongsNeverFailSilently() throws {
        for path in ["Sources/Providers/SubsonicProvider.swift", "Sources/Providers/JellyfinProvider.swift"] {
            let body = try Self.songItemsBody(path)
            #expect(body.contains("MusicSongsFailure.log(itemId: itemId, error)"), "\(path): no log line")
            #expect(!body.contains("try?"), "\(path): a fetch fails silently again")
        }
        let button = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/ShufflePlayButton.swift"), encoding: .utf8))
        #expect(button.contains("await Self.start(pool: pool, isOnline: isOnline, coordinator: playerCoordinator)"))
        // The reader finds the body and stops at its end.
        let subsonic = try Self.songItemsBody("Sources/Providers/SubsonicProvider.swift")
        #expect(subsonic.contains("learnCovers(songs)"))
        #expect(!subsonic.contains("func "), "the reader ran into the next function")
    }
}
#endif
