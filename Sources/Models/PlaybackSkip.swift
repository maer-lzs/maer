// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How far a skip jumps. Spoken word (books, podcasts) and music are two
/// habits: a sentence missed wants thirty seconds back, a song wants ten.
/// The choice is remembered per habit, so a song never resets the book.
nonisolated enum PlaybackSkip {
    enum Content: Sendable, Equatable {
        case spokenWord
        case music
    }

    /// The habit an item belongs to: music by family, and a catalogue item
    /// that is music by form (an album, a song), everything else spoken word.
    static func content(forItemId id: String) -> Content {
        MediaFamily.isMusicByForm(id) ? .music : .spokenWord
    }

    static func standardInterval(for content: Content) -> Double {
        switch content {
        case .spokenWord: return 30
        case .music: return 10
        }
    }

    /// The choices the player offers; each has an SF Symbol of its own.
    static func options(for content: Content) -> [Double] {
        switch content {
        case .spokenWord: return [15, 30, 60]
        case .music: return [5, 10, 15, 30]
        }
    }
}
