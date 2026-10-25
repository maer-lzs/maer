// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether a pull on the full player ends with the player closed: past the
/// threshold, or flung beyond twice it.
nonisolated enum PlayerDismiss {
    static func closes(translation: CGSize, predictedHeight: CGFloat, threshold: CGFloat) -> Bool {
        max(0, translation.height) > threshold || predictedHeight > threshold * 2
    }
}
