// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How a picture meets a square tile.
///
/// The grid is square and stays square: it carries every row and every
/// list, and a mixed grid falls apart visually. So a picture that is
/// close to square keeps being FILLED, exactly as before. A picture far
/// from square is FITTED instead, because filling costs it a third of
/// its width, and on a title card that is the difference between a word
/// and a fragment of a word.
///
/// The rule reads the picture, never its source. Video artwork arrives
/// from several places (feed bridges, some netlabels, wide scans), and a
/// source list would have to grow every time one is added.
nonisolated enum CoverAspect {
    /// How far from square a picture may be and still be filled. A 16:9
    /// picture sits at 0.78 and is fitted; a cover scanned a little off
    /// true sits far below and keeps today's behaviour.
    static let fillTolerance = 0.2

    /// The picture's distance from square: zero when square, 0.78 for
    /// 16:9, and the same for a portrait picture of the same proportion
    /// (the rule has no preference for landscape).
    static func distanceFromSquare(width: Double, height: Double) -> Double {
        guard width > 0, height > 0 else { return 0 }
        return max(width, height) / min(width, height) - 1
    }

    /// True when the picture must be fitted whole instead of filled.
    ///
    /// A degenerate size (a picture that has not reported its
    /// dimensions yet) answers false: the tile then behaves exactly as
    /// it does today, which is the safe direction. A wrong "fit" would
    /// change a cover that was already fine.
    static func needsFitting(width: Double, height: Double,
                             tolerance: Double = fillTolerance) -> Bool {
        distanceFromSquare(width: width, height: height) > tolerance
    }
}
