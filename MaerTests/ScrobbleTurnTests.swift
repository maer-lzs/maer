// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A music server counts a play once per song, as the song starts; the
/// progress calls come every few seconds, so the rule decides which of them
/// counts.
struct ScrobbleTurnTests {
    private let songs: [ScrobbleTurn.Song] = [("a", 0), ("b", 180), ("c", 400)]

    @Test("the running song is the last begun one, with half a second of play")
    func thePlayingSongIsTheLastStarted() {
        #expect(ScrobbleTurn.song(at: 0, in: songs)?.id == "a")
        #expect(ScrobbleTurn.song(at: 179, in: songs)?.id == "a")
        #expect(ScrobbleTurn.song(at: 179.6, in: songs)?.id == "b", "half a second before the start counts for the next song")
        #expect(ScrobbleTurn.song(at: 500, in: songs)?.id == "c")
        #expect(ScrobbleTurn.song(at: -5, in: [("x", 10)]) == nil, "before the first song nothing plays")
        #expect(ScrobbleTurn.song(at: 5, in: []) == nil)
    }

    @Test("counting happens at the change of song, not at every call")
    func aPlayCountsOncePerSong() {
        let first = ScrobbleTurn.song(at: 10, in: songs)
        #expect(ScrobbleTurn.due(first, last: nil) == "a", "the first song counts")
        #expect(ScrobbleTurn.due(ScrobbleTurn.song(at: 40, in: songs), last: "a") == nil, "the same song again does not")
        #expect(ScrobbleTurn.due(ScrobbleTurn.song(at: 200, in: songs), last: "a") == "b", "the next song counts")
        #expect(ScrobbleTurn.due(nil, last: "a") == nil)
        // A count the server refused is forgotten by the provider (last nil)
        // and asked again at the next call.
        #expect(ScrobbleTurn.due(ScrobbleTurn.song(at: 210, in: songs), last: nil) == "b")
    }

    /// The booking a provider's `updateProgress` keeps, driven call by call
    /// with a server that refuses once.
    @Test("the book of counts: once per song, a refused one counts anew at the next call, a newly loaded piece counts again")
    @MainActor
    func theBookCountsOncePerSongAndAsksARefusalAgain() async {
        final class Server { var sent: [String] = []; var refuses = false }
        let server = Server()
        let book = ScrobbleBook()
        let send: (String) async throws -> Void = { id in
            server.sent.append(id)
            if server.refuses { throw URLError(.badServerResponse) }
        }
        #expect(await book.count(ScrobbleTurn.song(at: 10, in: songs), in: "album", send: send) == nil)
        #expect(await book.count(ScrobbleTurn.song(at: 40, in: songs), in: "album", send: send) == nil)
        #expect(server.sent == ["a"], "the same song counts once")
        server.refuses = true
        let refused = await book.count(ScrobbleTurn.song(at: 200, in: songs), in: "album", send: send)
        #expect(refused?.song == "b", "a refused count comes back for the provider's line")
        #expect(book.last["album"] == nil, "a refused count is not booked as done")
        server.refuses = false
        #expect(await book.count(ScrobbleTurn.song(at: 210, in: songs), in: "album", send: send) == nil)
        #expect(server.sent == ["a", "b", "b"], "the next call asks the refused song again")
        #expect(book.last["album"] == "b")
        _ = await book.count(ScrobbleTurn.song(at: 10, in: songs), in: "other", send: send)
        #expect(server.sent.last == "a" && book.last["other"] == "a", "each item counts on its own")
        book.forget("album")
        _ = await book.count(ScrobbleTurn.song(at: 220, in: songs), in: "album", send: send)
        #expect(server.sent.last == "b", "a reloaded item counts its song again")
    }

    @Test("both music providers ask the one rule and no longer count a song themselves", .needsTheSources)
    func bothProvidersAskTheOneRule() throws {
        for name in ["SubsonicProvider.swift", "JellyfinProvider.swift"] {
            let code = SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/\(name)"), encoding: .utf8))
            #expect(code.contains("await scrobbles.count("), "\(name) no longer counts through the book")
            #expect(code.contains("scrobbles.forget(itemId)"), "\(name) does not count a reloaded item again")
            #expect(!code.contains("lastScrobbledSong"), "\(name) keeps a booking of its own again")
            #expect(!code.contains("$0.start <= currentTime"), "\(name) finds the playing song itself again")
            #expect(!code.contains("try? await client.markPlayed") && !code.contains("try? await client.scrobble"),
                    "\(name) swallows a refused count again")
        }
    }
}
#endif
