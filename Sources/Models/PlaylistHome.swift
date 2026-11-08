// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Where a device playlist stands, by what it holds. The one rule every
/// place asks: a list whose content changes moves with it.
nonisolated enum PlaylistHome: String, CaseIterable, Hashable, Sendable {
    /// Routines and lists that mix kinds (or hold radio or an unknown kind).
    case start
    case music
    case podcasts
    /// The audiobook library.
    case library

    /// The home of a list from the kinds of its entries (`MediaFamily.kind`,
    /// nil for an id no family knows). An empty list stays in the music tab,
    /// the one place a list is created without entries.
    static func of(kinds: [MediaType?], isRoutine: Bool) -> PlaylistHome {
        if isRoutine { return .start }
        guard let first = kinds.first else { return .music }
        guard kinds.allSatisfy({ $0 == first }) else { return .start }
        switch first {
        case .music: return .music
        case .podcasts: return .podcasts
        case .audiobooks: return .library
        case .radio, .home, nil: return .start
        }
    }

    /// The home of a list from its entry ids. `markedForm` answers the
    /// started form of an entry, which decides whether a catalogue title is
    /// a book or music.
    static func of(itemIds: [String], isRoutine: Bool,
                   markedForm: (String) -> ProgressMark.StartedForm?) -> PlaylistHome {
        of(kinds: itemIds.map { MediaFamily.kind(for: $0, markedForm: markedForm($0)) },
           isRoutine: isRoutine)
    }
}
