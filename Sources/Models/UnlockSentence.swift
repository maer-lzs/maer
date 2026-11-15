// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The sentence a start says when the device must be unlocked once before
/// the sign-in can be read: it names what was asked for, a book, an
/// episode or a title (a song or a station). Pure.
nonisolated enum UnlockSentence {
    enum Kind: Equatable {
        case book, episode, title
    }

    /// The kind of what plays: an episode by its id, a song or a station as
    /// a title, everything else as a book.
    static func kind(itemId: String, isMusic: Bool) -> Kind {
        if ItemNamespace.isPodcastEpisode(itemId) { return .episode }
        if isMusic || ItemNamespace.isRadio(itemId) { return .title }
        return .book
    }

    static func of(_ kind: Kind) -> String {
        switch kind {
        case .book: String(localized: "Unlock this device once to play this book.")
        case .episode: String(localized: "Unlock this device once to play this episode.")
        case .title: String(localized: "Unlock this device once to play this title.")
        }
    }
}
