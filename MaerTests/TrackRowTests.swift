// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The one row of album and playlist lists, and its mark for the song
/// that plays.
struct TrackRowTests {
    @Test("Die Zeile eines Albums oder einer Server-Playlist spielt, wenn ihr Eintrag beim Kapitel der Zeile steht")
    func aRowOfAnEntryPlaysAtItsChapter() {
        let row = TrackPlaying.Row(entryId: "sub:playlist:pl-1", start: 148, ownId: "sub:song:tr-2")
        #expect(TrackPlaying.isCurrent(row, playingId: "sub:playlist:pl-1", playingChapterStart: 148))
        #expect(TrackPlaying.isCurrent(row, playingId: "sub:playlist:pl-1", playingChapterStart: 148.2))
        #expect(!TrackPlaying.isCurrent(row, playingId: "sub:playlist:pl-1", playingChapterStart: 0),
                "another song of the same entry")
        #expect(!TrackPlaying.isCurrent(row, playingId: "sub:album:al-3", playingChapterStart: 148),
                "another entry at the same time")
        #expect(!TrackPlaying.isCurrent(row, playingId: nil, playingChapterStart: 148), "nothing plays")
        #expect(!TrackPlaying.isCurrent(row, playingId: "sub:playlist:pl-1", playingChapterStart: nil))
    }

    @Test("Ein Lied, das fuer sich spielt (Zufall, Geraete-Playlist), markiert seine Zeile")
    func aSongPlayedOnItsOwnMarksItsRow() {
        let inList = TrackPlaying.Row(entryId: "sub:playlist:pl-1", start: 148, ownId: "sub:song:tr-2")
        #expect(TrackPlaying.isCurrent(inList, playingId: "sub:song:tr-2", playingChapterStart: 0))
        let onDevice = TrackPlaying.Row(ownId: "sub:song:tr-2")
        #expect(TrackPlaying.isCurrent(onDevice, playingId: "sub:song:tr-2", playingChapterStart: nil))
        #expect(!TrackPlaying.isCurrent(onDevice, playingId: "sub:song:tr-9", playingChapterStart: nil))
    }

    @Test("Die Marke bewegt sich beim Spielen und steht in der Pause still")
    func theMarkMovesOnlyWhilePlaying() {
        let still = (0..<3).map { PlayingBars.share(bar: $0, at: 1, moving: false) }
        #expect(still == (0..<3).map { PlayingBars.share(bar: $0, at: 99, moving: false) }, "pause stands still")
        #expect(PlayingBars.share(bar: 0, at: 0.1, moving: true) != PlayingBars.share(bar: 0, at: 0.4, moving: true))
        for t in stride(from: 0.0, to: 3, by: 0.05) {
            let share = PlayingBars.share(bar: 1, at: t, moving: true)
            #expect(share >= 0.25 && share <= 1)
        }
    }

    /// Album, server playlist and device playlist draw the one row; the
    /// playlist rows lead with the song's cover and name the artist.
    @Test("Album, Server- und Geraete-Playlist zeichnen die eine Zeile, die Playlist mit Cover und Kuenstler", .needsTheSources)
    func everyListDrawsTheOneRow() throws {
        func flat(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path),
                                                       encoding: .utf8))
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let album = try flat("Sources/Views/Music/MusicAlbumView.swift")
        #expect(album.contains("TrackRowLabel(lead: isPlaylist ? .cover(songCoverURL(index), placeholder: \"music.note\") : .number(index + 1)"))
        #expect(album.contains("artist: isPlaylist ? audioTrack(index)?.metadata?.artist : nil"))
        #expect(album.contains("playing: TrackPlaying.Row(entryId: item.id, start: track.start, ownId: songItemId(index))"))
        let device = try flat("Sources/Views/Music/MusicLibraryPages.swift")
        #expect(device.contains("TrackRowLabel(lead: .cover(playlist.flatMap { PlaylistCardSource.deviceCover(of: id, in: $0, router: router) }"))
        #expect(device.contains("playing: TrackPlaying.Row(ownId: id)"))
        let row = try flat("Sources/Views/Music/PopularityBars.swift")
        #expect(!row.contains("struct AlbumTrackRowLabel"), "a second row is back")
        #expect(row.contains("TrackPlaying.isCurrent(row, playingId: playingId, playingChapterStart: viewModel.currentChapter?.start)"))
        #expect(row.contains("PlayingBars(moving: viewModel.isPlaying)"))
    }
}
#endif
