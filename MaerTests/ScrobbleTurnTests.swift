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

    @Test("der laufende Song ist der letzte begonnene, mit einer halben Sekunde Spiel")
    func thePlayingSongIsTheLastStarted() {
        #expect(ScrobbleTurn.song(at: 0, in: songs)?.id == "a")
        #expect(ScrobbleTurn.song(at: 179, in: songs)?.id == "a")
        #expect(ScrobbleTurn.song(at: 179.6, in: songs)?.id == "b", "half a second before the start counts for the next song")
        #expect(ScrobbleTurn.song(at: 500, in: songs)?.id == "c")
        #expect(ScrobbleTurn.song(at: -5, in: [("x", 10)]) == nil, "before the first song nothing plays")
        #expect(ScrobbleTurn.song(at: 5, in: []) == nil)
    }

    @Test("gezaehlt wird beim Wechsel des Songs, nicht bei jedem Aufruf")
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

    @Test("beide Musik-Anbieter fragen die eine Regel und zaehlen keinen Song mehr selbst", .needsTheSources)
    func bothProvidersAskTheOneRule() throws {
        for name in ["SubsonicProvider.swift", "JellyfinProvider.swift"] {
            let code = SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/\(name)"), encoding: .utf8))
            #expect(code.contains("ScrobbleTurn.due("), "\(name) no longer asks the rule")
            #expect(!code.contains("$0.start <= currentTime"), "\(name) finds the playing song itself again")
            #expect(!code.contains("try? await client.markPlayed") && !code.contains("try? await client.scrobble"),
                    "\(name) swallows a refused count again")
        }
    }
}
#endif
