// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Per-media-type accent color (UI layer — the MediaType model itself stays
/// Foundation-only). One central source so every surface that colors by type
/// (tab selectors today; now-playing markers later) reads from the same place
/// (Regel 2). Colors follow the dominant conventions users already know:
/// Audible = orange, Apple Podcasts = purple, Apple Music = red. Home is the
/// cross-type aggregation tab, so it stays neutral (adapts black/white per
/// scheme). Radio is reserved for the future tab.
///
/// System colors are used deliberately — they carry Apple's light/dark
/// adaptation, so the tint stays legible in both schemes without hand-tuning.
extension MediaType {
    var tint: Color {
        switch self {
        case .home: return .primary        // neutral: cross-type aggregation
        case .audiobooks: return .orange
        case .podcasts: return .purple
        case .music: return .red
        case .radio: return .cyan          // A1/F4: radio's type color (blue/cyan)
        }
    }
}
