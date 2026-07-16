#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// T9c: one derivation for lock-screen NowPlaying, CarPlay and the Live Activity.
/// Title is always the work (tested at the call sites); the chapter shows in the
/// subtitle only when it's a REAL chapter — never a fallback marker.
struct NowPlayingPresentationTests {
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
}
#endif
