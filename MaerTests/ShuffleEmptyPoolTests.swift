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
    @Test("ein leerer Vorrat startet nichts und sagt in den Worten der Albumseite, warum")
    func anEmptyPoolSaysWhy() async {
        let cases: [(ShufflePool, String)] = [
            (.failed, String(localized: "Couldn't load tracks")),
            (.offline, String(localized: "Not available offline")),
            (.empty, String(localized: "No tracks")),
        ]
        for (pool, sentence) in cases {
            let coordinator = PlayerCoordinator(provider: MockProvider())
            await ShufflePlayButton.start(pool: { pool }, coordinator: coordinator)
            #expect(coordinator.loadError == sentence, "\(pool) said \(coordinator.loadError ?? "nothing")")
        }
        #expect(ShufflePlayButton.sentence(for: .offline).1 == .network, "offline shows the network symbol")
    }

    @Test("der Vorrat eines Servers gibt seinen Grund mit: ohne Netz offline, sonst gescheitert, ohne Fehler leer")
    func theServerPoolCarriesItsReason() {
        #expect(ShufflePool.of([], failure: .network).items.isEmpty)
        if case .offline = ShufflePool.of([], failure: .network) {} else { Issue.record("no network is not offline") }
        if case .failed = ShufflePool.of([], failure: .server) {} else { Issue.record("a server failure is not a failure") }
        if case .empty = ShufflePool.of([], failure: nil) {} else { Issue.record("an empty answer is not empty") }
        if case .empty = ShufflePool.of([]) {} else { Issue.record("an empty list in hand is not empty") }
        MusicSongsFailure.log(itemId: "sub:al-witness", URLError(.notConnectedToInternet))
        #expect(MusicSongsFailure.take("sub:al-witness") == .network)
        #expect(MusicSongsFailure.take("sub:al-witness") == nil, "the cause is taken once")
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
        #expect(button.contains("await Self.start(pool: pool, coordinator: playerCoordinator)"))
        // The reader finds the body and stops at its end.
        let subsonic = try Self.songItemsBody("Sources/Providers/SubsonicProvider.swift")
        #expect(subsonic.contains("learnCovers(songs)"))
        #expect(!subsonic.contains("func "), "the reader ran into the next function")
    }
}
#endif
