// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Content type of a source/item. Decides which bottom tab it lives in.
/// Tabs group by type, not source: several sources of the same type
/// (e.g. Audiobookshelf + local files) share one tab.
/// `nonisolated`: the type is a plain tag. It has to be usable inside the pure
/// rules that decide which source feeds which tab, and those run off the main
/// actor (the project default would isolate it).
nonisolated enum MediaType: String, CaseIterable, Identifiable, Sendable {
    case home          // aggregation tab (not a source); always first + default
    case audiobooks
    case podcasts
    case music
    case radio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return String(localized: "Home")
        case .audiobooks: return String(localized: "Audiobooks")
        case .podcasts: return String(localized: "Podcasts")
        case .music: return String(localized: "Music")
        case .radio: return String(localized: "Radio")
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .audiobooks: return "book.closed"
        case .podcasts: return "mic"
        case .music: return "music.note"
        case .radio: return "dot.radiowaves.left.and.right"
        }
    }
}
