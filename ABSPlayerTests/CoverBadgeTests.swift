#if canImport(Testing)
import Testing
import CoreGraphics
@testable import ABSPlayer

/// S11c/S14c: the shared badge size is 22% of the tile width, clamped [18, 44].
struct CoverBadgeTests {
    @Test("badge size is 22% of the tile, clamped to [18, 44]")
    func size() {
        #expect(CoverBadge.size(tileWidth: 160) == 160 * 0.22)   // 35.2, in range
        #expect(CoverBadge.size(tileWidth: 60) == 18)            // 13.2 → clamped up
        #expect(CoverBadge.size(tileWidth: 400) == 44)           // 88 → clamped down
        #expect(CoverBadge.size(tileWidth: 200) == 44)           // exactly the cap
    }
}
#endif
