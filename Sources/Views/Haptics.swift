// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import UIKit

/// Small central helper for haptic feedback. Deliberately subtle (a light
/// impulse) so play/pause and chapter jumps feel "premium" without being
/// intrusive.
enum Haptics {
    @MainActor
    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
}
