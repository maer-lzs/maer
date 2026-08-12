// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
@testable import ABSPlayer

/// Carrying a stored album position over to the song it falls into — checked
/// against an IMPORTED stock, not only against entries the app just wrote.
///
/// The general form behind this: every healing and migration path is checked
/// against imported state. An import produces many entries at once, all with
/// the same timestamp and without a reference point — that is what a new user
/// starts with, and it is the shape that slipped past the stock repair.
struct CatalogPositionMigrationTests {
    private let importStamp: Double = 1_753_180_608_000

    private func tracks(_ durations: [Double]) -> [ABSAudioTrack] {
        var offset: Double = 0
        return durations.enumerated().map { index, duration in
            defer { offset += duration }
            return ABSAudioTrack(index: index, startOffset: offset, duration: duration,
                                 contentUrl: "https://x/\(index).mp3", metadata: nil)
        }
    }

    @Test("an imported album position lands on its song, with its own moment")
    func importedAlbumPosition() throws {
        // 4th track, 30 s in — an entry from an import: two values, and the
        // timestamp is the import moment, not now.
        let carried = try #require(CatalogPositionMigration.songEntry(
            albumPosition: [630, importStamp],
            tracks: tracks([180, 180, 180, 180, 180]),
            songAlreadyHasEntry: false))
        #expect(carried.index == 3)
        #expect(carried.entry[0] == 90)
        // The moment of listening travels along unchanged — every merge in the
        // app decides by it, so a fresh stamp would let the copy win against
        // the entry it came from.
        #expect(ProgressMark.timestamp(carried.entry) == importStamp)
        // And the song's own duration rides along as the reference point.
        #expect(ProgressMark.markedDuration(carried.entry) == 180)
    }

    @Test("an existing song position is never overwritten")
    func neverOverwrites() {
        #expect(CatalogPositionMigration.songEntry(
            albumPosition: [630, importStamp],
            tracks: tracks([180, 180, 180, 180]),
            songAlreadyHasEntry: true) == nil)
    }

    @Test("nothing is invented")
    func inventsNothing() {
        let list = tracks([180, 180])
        // Position zero is not a place someone was.
        #expect(CatalogPositionMigration.songEntry(
            albumPosition: [0, importStamp], tracks: list, songAlreadyHasEntry: false) == nil)
        // An entry without a timestamp is not one.
        #expect(CatalogPositionMigration.songEntry(
            albumPosition: [90], tracks: list, songAlreadyHasEntry: false) == nil)
        // No tracks, nothing to carry over to.
        #expect(CatalogPositionMigration.songEntry(
            albumPosition: [90, importStamp], tracks: [], songAlreadyHasEntry: false) == nil)
    }

    /// A whole imported release: every position lands on the track it falls in,
    /// and each one keeps the import moment.
    @Test("a whole imported release carries over consistently")
    func wholeImportedRelease() throws {
        let list = tracks([200, 200, 200, 200, 200])
        for (position, expected) in [(10.0, 0), (210.0, 1), (410.0, 2), (610.0, 3), (810.0, 4)] {
            let carried = try #require(CatalogPositionMigration.songEntry(
                albumPosition: [position, importStamp], tracks: list, songAlreadyHasEntry: false))
            #expect(carried.index == expected)
            #expect(ProgressMark.timestamp(carried.entry) == importStamp)
        }
    }
}
