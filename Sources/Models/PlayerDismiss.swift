// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether a touch on the full player ends with the player closed: a pull
/// past the threshold or flung beyond twice it, and on the grab handle also
/// a tap. The handle's pull takes every touch first, so a tap on it is a
/// pull that did not move; it closes the same way.
nonisolated enum PlayerDismiss {
    /// A touch that moved less than this is a tap.
    static let tapSlop: CGFloat = 10

    static func closes(translation: CGSize, predictedHeight: CGFloat, threshold: CGFloat,
                       onHandle: Bool) -> Bool {
        let down = max(0, translation.height)
        if down > threshold || predictedHeight > threshold * 2 { return true }
        return onHandle && abs(translation.width) < tapSlop && abs(translation.height) < tapSlop
    }
}
