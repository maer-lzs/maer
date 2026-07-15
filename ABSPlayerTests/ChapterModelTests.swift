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
}
#endif
