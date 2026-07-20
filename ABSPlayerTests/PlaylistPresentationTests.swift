// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// F5: the pure playlist-card presentation rules.
struct PlaylistPresentationTests {
    @Test("mosaic tile count degrades gracefully 0…4+")
    func mosaicTiles() {
        #expect(PlaylistPresentation.mosaicTileCount(0) == 0)
        #expect(PlaylistPresentation.mosaicTileCount(1) == 1)
        #expect(PlaylistPresentation.mosaicTileCount(2) == 2)
        #expect(PlaylistPresentation.mosaicTileCount(3) == 3)
        #expect(PlaylistPresentation.mosaicTileCount(4) == 4)
        #expect(PlaylistPresentation.mosaicTileCount(9) == 4)   // caps at a full 2×2
        #expect(PlaylistPresentation.mosaicTileCount(-3) == 0)
    }

    @Test("duration text: H:MM at an hour or more, else M:SS")
    func duration() {
        #expect(PlaylistPresentation.durationText(seconds: 4320) == "1:12")   // 1h12m
        #expect(PlaylistPresentation.durationText(seconds: 600) == "10:00")
        #expect(PlaylistPresentation.durationText(seconds: 225) == "3:45")
        #expect(PlaylistPresentation.durationText(seconds: 0) == "0:00")
    }

    @Test("changed timestamp parses ISO-8601 (with and without fractional seconds)")
    func changed() {
        #expect(PlaylistPresentation.changedDate("2026-07-20T10:00:00Z") != nil)
        #expect(PlaylistPresentation.changedDate("2026-07-20T10:00:00.123Z") != nil)
        #expect(PlaylistPresentation.changedDate(nil) == nil)
        #expect(PlaylistPresentation.changedDate("not a date") == nil)
    }

    @Test("sort: newest changed first, undated last, stable")
    func sort() {
        struct P { let name: String; let changed: String? }
        let input = [
            P(name: "old", changed: "2026-07-18T10:00:00Z"),
            P(name: "none", changed: nil),
            P(name: "new", changed: "2026-07-20T10:00:00Z"),
            P(name: "mid", changed: "2026-07-19T10:00:00Z"),
        ]
        let sorted = PlaylistPresentation.sortedByChanged(input) {
            PlaylistPresentation.changedDate($0.changed)
        }
        #expect(sorted.map(\.name) == ["new", "mid", "old", "none"])
    }
}
#endif
