// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import SwiftUI
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

    @Test("Eine Album-Zeile nennt den Kuenstler des Liedes nur, wenn er nicht der des Albums ist")
    func anAlbumRowNamesOnlyADifferentArtist() {
        #expect(TrackRowArtist.inAlbum(song: "Ayato", album: "Ayato") == nil, "an album of one artist")
        #expect(TrackRowArtist.inAlbum(song: "  björk ", album: "Bjork") == nil, "case, accents and spaces are no difference")
        #expect(TrackRowArtist.inAlbum(song: "Nina Simone", album: "Various Artists") == "Nina Simone", "a sampler")
        #expect(TrackRowArtist.inAlbum(song: "Ayato feat. Mio", album: "Ayato") == "Ayato feat. Mio")
        #expect(TrackRowArtist.inAlbum(song: "Ayato", album: nil) == "Ayato", "an album without an artist")
        #expect(TrackRowArtist.inAlbum(song: "Ayato", album: " ") == "Ayato")
        #expect(TrackRowArtist.inAlbum(song: nil, album: "Various Artists") == nil, "a song without an artist")
        #expect(TrackRowArtist.inAlbum(song: "", album: "Ayato") == nil)
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
        let flat = FetchAnswerTests.squeezedSource
        let album = try flat("Sources/Views/Music/MusicAlbumView.swift")
        #expect(album.contains("TrackRowLabel(lead: isPlaylist ? .cover(songCoverURL(index), placeholder: \"music.note\") : .number(index + 1)"))
        #expect(album.contains("artist: rowArtist(index)"))
        #expect(album.contains("if isPlaylist { return song } return TrackRowArtist.inAlbum(song: song, album: detail?.media.metadata?.authorName ?? item.author)"))
        #expect(album.contains("playing: TrackPlaying.Row(entryId: item.id, start: track.start, ownId: songItemId(index))"))
        let device = try flat("Sources/Views/Music/MusicLibraryPages.swift")
        #expect(device.contains("TrackRowLabel(lead: .cover(playlist.flatMap { PlaylistCardSource.deviceCover(of: id, in: $0, router: router) }"))
        #expect(device.contains("playing: TrackPlaying.Row(ownId: id)"))
        let row = try flat("Sources/Views/Music/PopularityBars.swift")
        #expect(!row.contains("struct AlbumTrackRowLabel"), "a second row is back")
        #expect(row.contains("TrackPlaying.isCurrent(row, playingId: playingId, playingChapterStart: viewModel.currentChapter?.start)"))
        #expect(row.contains("PlayingBars(moving: viewModel.isPlaying)"))
    }

    /// The row as laid out at a phone's width and the given text size.
    @MainActor
    private func height(of label: TrackRowLabel, at size: DynamicTypeSize = .large) -> CGFloat {
        UIHostingController(rootView: label.environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: 340, height: CGFloat.greatestFiniteMagnitude)).height
    }

    /// A rule's reason is longer than a line: without a limit it stands
    /// whole and the row grows, at the default size beyond one line and at
    /// xxxL beyond two, where two lines cut it; a track keeps one line, and
    /// a short reason takes no more room without a limit.
    @Test("der Grund einer Regel steht in jeder Schriftgroesse ganz da; ein Lied bleibt einzeilig")
    @MainActor
    func aRulesReasonStandsWholeAtEverySize() {
        let reason = RoutineWords.answer(.showUnknown)
        let short = RoutineWords.rule(.newest)
        func row(_ lines: Int?, _ text: String) -> TrackRowLabel {
            TrackRowLabel(lead: .cover(nil, placeholder: "mic"), title: "Sendung", unavailable: text, secondLines: lines)
        }
        #expect(TrackRowLabel(lead: .number(1), title: "Lied").secondLines == 1, "a track keeps one line")
        #expect(height(of: row(nil, reason)) > height(of: row(1, reason)), "the reason is cut after one line")
        #expect(height(of: row(nil, reason), at: .xxxLarge) > height(of: row(2, reason), at: .xxxLarge),
                "at xxxL two lines cut the reason")
        #expect(height(of: row(nil, short)) == height(of: row(1, short)), "a short reason grows the row")
    }

    /// The rule's row lifts the limit; the lists of songs do not.
    @Test("die Zeile einer Regel nimmt fuer den Grund so viele Zeilen, wie er braucht, die Listen der Lieder keine", .needsTheSources)
    func onlyTheRuleLiftsTheLimit() throws {
        let flat = FetchAnswerTests.squeezedSource
        #expect(try flat("Sources/Views/Music/RoutineRuleRow.swift").contains("unavailable: plays ? nil : said, secondLines: nil)"))
        for file in ["Sources/Views/Music/MusicAlbumView.swift", "Sources/Views/Music/MusicLibraryPages.swift"] {
            #expect(!(try flat(file)).contains("secondLines:"), "\(file) widens its rows")
        }
    }
}
#endif
