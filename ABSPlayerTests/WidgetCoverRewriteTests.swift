#if canImport(Testing)
import Testing
import UIKit
@testable import ABSPlayer

/// V8: the home widget's shared cover file must be rewritten exactly on an
/// item change so the widget never shows a stale cover next to a new title.
@MainActor
struct WidgetCoverRewriteTests {
    @Test("cover is rewritten on the first item and on every change, not for the same item")
    func rewriteOnItemChange() {
        #expect(PlayerViewModel.coverNeedsRewrite(previous: nil, current: "a"))     // first item
        #expect(PlayerViewModel.coverNeedsRewrite(previous: "a", current: "b"))     // changed
        #expect(!PlayerViewModel.coverNeedsRewrite(previous: "a", current: "a"))    // same → no rewrite
    }

    /// X9/V8: the shared cover is downscaled so the app-group PNG stays small.
    @Test("downscaled caps the longest side; small images pass through")
    func downscale() {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 800)).image { _ in }
        let small = PlayerViewModel.downscaled(big, maxPixel: 300)
        #expect(max(small.size.width, small.size.height) <= 300)
        #expect(abs(small.size.width / small.size.height - 1000.0 / 800.0) < 0.01)   // aspect kept

        let tiny = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { _ in }
        #expect(PlayerViewModel.downscaled(tiny, maxPixel: 300).size == CGSize(width: 120, height: 120))
    }
}
#endif
