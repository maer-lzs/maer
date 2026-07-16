#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// S19: broken chapter metadata (Armageddon repro) must not produce nonsense
/// chapter labels / negative "min left". ChapterModel drops untrustworthy
/// chapters and only reports a current chapter that actually contains the time.
struct ChapterModelTests {

    private func ch(_ id: Int, _ start: Double, _ end: Double) -> ABSChapter {
        ABSChapter(id: id, start: start, end: end, title: "C\(id)")
    }

    @Test("Valid contiguous chapters are all kept, in order")
    func validKept() {
        let raw = [ch(0, 0, 100), ch(1, 100, 200), ch(2, 200, 300)]
        let v = ChapterModel.validated(raw, duration: 300)
        #expect(v.map(\.id) == [0, 1, 2])
    }

    @Test("Zero-length / reversed chapters are dropped")
    func zeroLengthDropped() {
        let raw = [ch(0, 0, 100), ch(1, 100, 100), ch(2, 200, 150), ch(3, 200, 300)]
        let v = ChapterModel.validated(raw, duration: 300)
        #expect(v.map(\.id) == [0, 3])
    }

    @Test("Overlapping chapters: the overlapper is dropped")
    func overlapDropped() {
        // ch1 (50–250) overlaps ch0 (0–100) → dropped; ch2 (100–200) fits.
        let raw = [ch(0, 0, 100), ch(1, 50, 250), ch(2, 100, 200)]
        let v = ChapterModel.validated(raw, duration: 300)
        #expect(v.map(\.id) == [0, 2])
    }

    @Test("Out-of-range chapters (start past end / end beyond duration) are dropped")
    func outOfRangeDropped() {
        let raw = [ch(0, 0, 100), ch(1, 100, 5000), ch(2, 9000, 9100), ch(3, -10, 50)]
        let v = ChapterModel.validated(raw, duration: 300)
        // ch1 end beyond duration, ch2 start past duration, ch3 negative start → all dropped.
        #expect(v.map(\.id) == [0])
    }

    @Test("Unknown duration (0): only span/overlap checks apply")
    func unknownDuration() {
        let raw = [ch(0, 0, 100), ch(1, 100, 99999)]
        let v = ChapterModel.validated(raw, duration: 0)
        #expect(v.map(\.id) == [0, 1])
    }

    @Test("current(at:) finds the containing chapter, nil in gaps / past the end")
    func currentLookup() {
        let v = [ch(0, 0, 100), ch(1, 100, 200)]
        #expect(ChapterModel.current(at: 50, in: v)?.id == 0)
        #expect(ChapterModel.current(at: 150, in: v)?.id == 1)
        #expect(ChapterModel.current(at: 100, in: v)?.id == 1)   // boundary belongs to next
        #expect(ChapterModel.current(at: 250, in: v) == nil)     // past the end
        #expect(ChapterModel.current(at: 0, in: []) == nil)      // no chapters
    }

    @Test("A gap between valid chapters yields nil (omit) rather than a wrong chapter")
    func gapYieldsNil() {
        // After dropping the broken middle chapter a 100–200 gap remains.
        let raw = [ch(0, 0, 100), ch(1, 100, 50), ch(2, 200, 300)]
        let v = ChapterModel.validated(raw, duration: 300)
        #expect(v.map(\.id) == [0, 2])
        #expect(ChapterModel.current(at: 150, in: v) == nil)
    }

    // MARK: - S19b coverage + track fallback

    private func trk(_ i: Int, _ start: Double, _ dur: Double) -> ABSAudioTrack {
        ABSAudioTrack(index: i, startOffset: start, duration: dur, contentUrl: "f\(i)", metadata: nil)
    }

    @Test("coversBook: reliable at >=90%, unreliable below / empty")
    func coverage() {
        #expect(ChapterModel.coversBook([ch(0, 0, 100), ch(1, 900, 1000)], duration: 1000) == true)
        #expect(ChapterModel.coversBook([ch(0, 0, 100), ch(1, 800, 850)], duration: 1000) == false)
        #expect(ChapterModel.coversBook([], duration: 1000) == false)
    }

    @Test("resolved: chapters that cover the book are kept (not a fallback)")
    func resolvedReliable() {
        let r = ChapterModel.resolved(chapters: [ch(0, 0, 500), ch(1, 500, 1000)], tracks: [], duration: 1000)
        #expect(r.isFallback == false)
        #expect(r.chapters.map(\.id) == [0, 1])
    }

    @Test("resolved: partial chapters + multi-track -> one chapter per track (mp3 case)")
    func resolvedMultiTrack() {
        let tracks = [trk(0, 0, 300), trk(1, 300, 300), trk(2, 600, 400)]
        let r = ChapterModel.resolved(chapters: [ch(0, 0, 100)], tracks: tracks, duration: 1000)
        #expect(r.isFallback == true)
        #expect(r.chapters.map(\.start) == [0, 300, 600])
        #expect(r.chapters.last?.end == 1000)
    }

    @Test("resolved: partial chapters + single file -> chapters + remaining (m4b case)")
    func resolvedSingleFile() {
        let r = ChapterModel.resolved(chapters: [ch(0, 0, 100), ch(1, 100, 200)],
                                      tracks: [trk(0, 0, 1000)], duration: 1000)
        #expect(r.isFallback == true)
        #expect(r.chapters.count == 3)               // 2 chapters + "remaining"
        #expect(r.chapters.last?.start == 200)
        #expect(r.chapters.last?.end == 1000)
    }

    @Test("resolved: 90% coverage (last chapter END) is the cutoff")
    func resolvedBoundary() {
        let tracks = [trk(0, 0, 500), trk(1, 500, 500)]
        // last END at 900 (90%) → reliable; at 890 (89%) → fallback.
        #expect(ChapterModel.resolved(chapters: [ch(0, 0, 100), ch(1, 100, 900)],
                                      tracks: tracks, duration: 1000).isFallback == false)
        #expect(ChapterModel.resolved(chapters: [ch(0, 0, 100), ch(1, 100, 890)],
                                      tracks: tracks, duration: 1000).isFallback == true)
    }

    @Test("resolved: empty chapters + multi-track -> track fallback")
    func resolvedEmptyMultiTrack() {
        let r = ChapterModel.resolved(chapters: [], tracks: [trk(0, 0, 300), trk(1, 300, 300)], duration: 600)
        #expect(r.isFallback == true)
        #expect(r.chapters.count == 2)
    }

    // MARK: - T9b: media-type-aware coverage (book vs podcast fixtures)

    /// The SAME partial-coverage chapters: a BOOK gets the fallback/rest marker,
    /// a PODCAST keeps them as-is (segment markers are legitimate there).
    @Test("T9b: partial coverage — book falls back, podcast is kept as-is")
    func partialCoverageByMediaType() {
        let raw = [ch(0, 0, 100), ch(1, 100, 300)]   // ends at 300 of 1000 = 30%
        let book = ChapterModel.resolved(chapters: raw, tracks: [trk(0, 0, 1000)], duration: 1000,
                                         isPodcast: false)
        #expect(book.isFallback == true)              // book → fallback (rest marker)
        #expect(book.chapters.count == 3)

        let podcast = ChapterModel.resolved(chapters: raw, tracks: [trk(0, 0, 1000)], duration: 1000,
                                            isPodcast: true)
        #expect(podcast.isFallback == false)          // podcast → as-is
        #expect(podcast.chapters.map(\.id) == [0, 1]) // NO rest marker appended
    }

    @Test("T9b: podcast with NO chapters stays empty (no track fallback)")
    func podcastNoChapters() {
        let r = ChapterModel.resolved(chapters: [], tracks: [trk(0, 0, 500), trk(1, 500, 500)],
                                      duration: 1000, isPodcast: true)
        #expect(r.isFallback == false)
        #expect(r.chapters.isEmpty)
    }

    /// V6: displays must derive the current chapter from the VALIDATED list, not
    /// the raw server chapters. "Letzte Flotte" shape: chapters cover only the
    /// first ~30% of the book; past that, the raw `last(where: t >= start)` names
    /// a phantom chapter, while validated `current` correctly returns nil.
    @Test("V6: raw chapters name a phantom chapter past coverage; validated does not")
    func v6CoverageFallbackChapterLabel() {
        let raw = [ch(0, 0, 100), ch(1, 100, 300)]   // covers 30% of a 1000s book
        // The V6 bug (raw): position 500 → last chapter whose start <= 500 = C1.
        #expect(raw.last(where: { 500 >= $0.start })?.id == 1)
        // The fix (validated + current): 500 is past the last end → nil.
        let validated = ChapterModel.validated(raw, duration: 1000)
        #expect(ChapterModel.current(at: 500, in: validated) == nil)
        // Inside a real chapter it still resolves correctly.
        #expect(ChapterModel.current(at: 150, in: validated)?.id == 1)
    }

    @Test("T9b: the book rest marker is labelled by its start position")
    func restMarkerLabelledByPosition() {
        let r = ChapterModel.resolved(chapters: [ch(0, 0, 100)], tracks: [trk(0, 0, 1000)], duration: 1000)
        #expect(r.isFallback == true)
        // timeLabel(100) == "1:40" → "Rest from 1:40" (not the old "Remaining").
        #expect(r.chapters.last?.title.contains("1:40") == true)
        #expect(r.chapters.last?.title.contains("Rest") == true)
    }
}
#endif
