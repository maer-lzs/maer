#if canImport(Testing) && DEBUG
import Testing
@testable import ABSPlayer

/// X16d: markPlayedAndAdvance must ONLY act when the marked item is the active
/// session. A non-active item is a no-op (the callers already drop it from the
/// queue); acting on it would interrupt whatever is playing.
@MainActor
struct MarkPlayedAdvanceTests {

    private func item(_ id: String) -> LibraryItem {
        LibraryItem(id: id, media: media(id), addedAt: nil)
    }
    private func detail(_ id: String) -> LibraryItemDetail {
        LibraryItemDetail(id: id, media: media(id), userMediaProgress: nil)
    }
    private func media(_ title: String) -> LibraryItemMedia {
        LibraryItemMedia(
            metadata: LibraryItemMetadata(title: title, authorName: nil, narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: 100, chapters: nil, tracks: nil)
    }

    @Test("marking a NON-active item is a no-op — no advance, active session untouched")
    func nonActiveIsNoOp() {
        let coord = PlayerCoordinator(provider: MockProvider())
        coord._seedActivePlayerForUITest(item: item("A"), detail: detail("A"),
                                         chapters: [], currentChapterIndex: 0, isFallback: false)
        PlayQueue.shared.clear()
        PlayQueue.shared.playLast("B")

        coord.markPlayedAndAdvance(itemId: "B")   // "B" is NOT the active session

        #expect(coord.activeItem?.id == "A")          // session left running
        #expect(coord.viewModel != nil)
        #expect(PlayQueue.shared.ids.contains("B"))   // "B" not consumed → no advance
        PlayQueue.shared.clear()
    }

    @Test("marking the ACTIVE item ends the session and enters the advance flow")
    func activeEndsAndAdvances() {
        let coord = PlayerCoordinator(provider: MockProvider())
        coord._seedActivePlayerForUITest(item: item("A"), detail: detail("A"),
                                         chapters: [], currentChapterIndex: 0, isFallback: false)
        PlayQueue.shared.clear()   // empty queue → the advance ends the session (no next)

        coord.markPlayedAndAdvance(itemId: "A")   // "A" IS the active session

        #expect(coord.viewModel == nil)    // playback stopped
        #expect(coord.activeItem == nil)   // session ended; advanceAfterFinish ran
    }
}
#endif
