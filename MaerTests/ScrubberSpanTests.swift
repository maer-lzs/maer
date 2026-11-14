// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The progress bar spans the work for spoken word and the SONG for
/// music, as every music player does.
struct ScrubberSpanTests {
    /// An album of three songs, 200 s each.
    let second = ScrubberSpan.of(isMusic: true, chapterStart: 200, chapterEnd: 400, duration: 600)

    @Test("Music: the bar is the song, with its times")
    func musicSpansTheSong() {
        #expect(second.length == 200)
        // Half way into the second song.
        #expect(second.elapsed(absolute: 300) == 100)
        #expect(second.remaining(absolute: 300) == 100)
        // Dragging to the middle of the bar seeks inside the song.
        #expect(second.absolute(position: 100) == 300)
    }

    @Test("Spoken word: the bar is the work, unchanged")
    func spokenWordSpansTheWork() {
        let book = ScrubberSpan.of(isMusic: false, chapterStart: 200, chapterEnd: 400, duration: 600)
        #expect(book == .span(start: 0, end: 600))
        #expect(book.elapsed(absolute: 300) == 300)
        #expect(book.remaining(absolute: 300) == 300)
        #expect(book.absolute(position: 120) == 120)
    }

    @Test("Without a song, music falls back to the work (a single track, a stream)")
    func musicWithoutASongKeepsTheWork() {
        #expect(ScrubberSpan.of(isMusic: true, chapterStart: nil, chapterEnd: nil, duration: 240)
                == .span(start: 0, end: 240))
        // A degenerate chapter is no song either.
        #expect(ScrubberSpan.of(isMusic: true, chapterStart: 100, chapterEnd: 100, duration: 240)
                == .span(start: 0, end: 240))
        // And a player without a duration still has a range.
        #expect(ScrubberSpan.of(isMusic: false, chapterStart: nil, chapterEnd: nil, duration: 0).length == 1)
    }

    @Test("The edges: zero before the song, the full length after it, a drag outside stays inside")
    func edgesStayInsideTheSpan() {
        #expect(second.elapsed(absolute: 0) == 0)
        #expect(second.elapsed(absolute: 999) == 200)
        #expect(second.remaining(absolute: 999) == 0)
        #expect(second.absolute(position: -50) == 200)
        #expect(second.absolute(position: 9_999) == 400)
    }
}
#endif
