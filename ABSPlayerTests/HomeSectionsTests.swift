#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// Etappe 3: Home ranks strictly by timestamp, merges sources, de-dups by id.
struct HomeSectionsTests {
    @Test("byRecency merges sources newest-first, de-duplicated, capped")
    func merge() {
        let books = [("b1", 30.0), ("b2", 10.0)]
        let episodes = [("e1", 20.0), ("b1", 40.0)]   // b1 also here, newer ts
        let r = HomeSections.byRecency([books, episodes], limit: 10)
        // b1 keeps its newest ts (40) → first; then e1 (20), b2 (10).
        #expect(r == ["b1", "e1", "b2"])
    }

    @Test("byRecency caps at the limit")
    func cap() {
        let src = (0..<20).map { (id: "i\($0)", ts: Double($0)) }
        #expect(HomeSections.byRecency([src], limit: 5).count == 5)
        #expect(HomeSections.byRecency([src], limit: 5).first == "i19")   // newest
    }

    @Test("byRecency on empty sources is empty")
    func empty() {
        #expect(HomeSections.byRecency([], limit: 5).isEmpty)
        #expect(HomeSections.byRecency([[]], limit: 5).isEmpty)
    }
}
#endif
