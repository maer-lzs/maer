// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// T9c: one derivation for lock-screen NowPlaying and CarPlay.
/// Title is always the work (tested at the call sites); the chapter shows in the
/// subtitle only when it's a REAL chapter. Never a fallback marker.
struct NowPlayingPresentationTests {
    @Test("Mini-Player: bei einem Song fuehrt der Kuenstler die zweite Zeile, nie der Titel noch einmal")
    func miniLeadForASongIsTheArtist() {
        #expect(NowPlayingPresentation.miniLead(isMusic: true, chapterTitle: "Diavolo rosso",
                                                artist: "Paolo Conte") == "Paolo Conte")
        #expect(NowPlayingPresentation.miniLead(isMusic: true, chapterTitle: "Diavolo rosso",
                                                artist: nil) == nil, "without an artist the time stands alone")
        #expect(NowPlayingPresentation.miniLead(isMusic: false, chapterTitle: "Chapter 2",
                                                artist: "Andrea Wulf") == "Chapter 2", "a book keeps its chapter")
    }

    @Test("real chapter + author form the subtitle")
    func realChapter() {
        #expect(NowPlayingPresentation.subtitle(chapterTitle: "Chapter 2", author: "Andrea Wulf",
                                                isFallback: false) == "Chapter 2 · Andrea Wulf")
    }

    @Test("a fallback marker never appears; the author alone remains")
    func fallbackExcluded() {
        #expect(NowPlayingPresentation.subtitle(chapterTitle: "Part 3 of 12", author: "Andrea Wulf",
                                                isFallback: true) == "Andrea Wulf")
    }

    @Test("chapter only when there is no author")
    func chapterOnly() {
        #expect(NowPlayingPresentation.subtitle(chapterTitle: "Chapter 1", author: nil,
                                                isFallback: false) == "Chapter 1")
    }

    @Test("nothing to show → nil (also empty/whitespace)")
    func empty() {
        #expect(NowPlayingPresentation.subtitle(chapterTitle: nil, author: nil, isFallback: false) == nil)
        #expect(NowPlayingPresentation.subtitle(chapterTitle: "", author: "  ", isFallback: false) == nil)
    }

    // MARK: - X14: the large title is always the work, never empty

    @Test("book: the work title is the book, not the chapter")
    func bookTitle() {
        #expect(NowPlayingPresentation.title(isMusic: false, songTitle: nil,
                                             workTitle: "Die Letzte Flotte", fallback: "Audiobook")
                == "Die Letzte Flotte")
    }

    @Test("episode: the work title is the episode title")
    func episodeTitle() {
        #expect(NowPlayingPresentation.title(isMusic: false, songTitle: nil,
                                             workTitle: "Folge 42", fallback: "Audiobook")
                == "Folge 42")
    }

    @Test("song: the work title is the SONG, not the album")
    func songTitle() {
        // Music: the song is the work; the album is passed as workTitle and must
        // NOT win.
        #expect(NowPlayingPresentation.title(isMusic: true, songTitle: "Bohemian Rhapsody",
                                             workTitle: "A Night at the Opera", fallback: "Audiobook")
                == "Bohemian Rhapsody")
    }

    @Test("fallback-chapter book: the title is STILL the work, never the cleaned chapter or empty")
    func fallbackChapterBookKeepsWorkTitle() {
        // The X14 regression: with T9d's cleaned chapters ("Teil 12"), the work
        // title must come from the work itself, not the chapter. And never blank.
        let title = NowPlayingPresentation.title(isMusic: false, songTitle: nil,
                                                 workTitle: "Armageddon", fallback: "Audiobook")
        #expect(title == "Armageddon")
        #expect(!title.isEmpty)
    }

    @Test("title never blank — missing/whitespace work title falls back to the generic label")
    func titleNeverEmpty() {
        #expect(NowPlayingPresentation.title(isMusic: false, songTitle: nil,
                                             workTitle: nil, fallback: "Audiobook") == "Audiobook")
        #expect(NowPlayingPresentation.title(isMusic: false, songTitle: nil,
                                             workTitle: "   ", fallback: "Audiobook") == "Audiobook")
        // Music with a blank song title falls back to the album, then the label.
        #expect(NowPlayingPresentation.title(isMusic: true, songTitle: "  ",
                                             workTitle: "The Album", fallback: "Audiobook") == "The Album")
    }
}
#endif
