// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a request to continue listening does, from what is known at the
/// moment it is asked: a title Siri named comes first, then a player that
/// is open, then the last played title. A title not found while the library
/// still loads waits for the load; anything else not found is nothing, and
/// `missing` says what was asked.
nonisolated enum ResumeTarget: Equatable {
    case item(String)
    case resumeActive
    case lastPlayed(String)
    case waitForLibrary
    case nothing(missing: String)

    /// The case without its id, for a log line.
    var name: String {
        switch self {
        case .item: "item"
        case .resumeActive: "resume-active"
        case .lastPlayed: "last-played"
        case .waitForLibrary: "wait-for-library"
        case .nothing: "nothing"
        }
    }

    static func pick(namedItemId: String?, namedItemKnown: Bool, hasActivePlayer: Bool,
                     lastPlayedId: String?, lastPlayedKnown: Bool, libraryLoading: Bool) -> ResumeTarget {
        if let namedItemId {
            if namedItemKnown { return .item(namedItemId) }
            return libraryLoading ? .waitForLibrary : .nothing(missing: "item")
        }
        if hasActivePlayer { return .resumeActive }
        guard let lastPlayedId, lastPlayedKnown else {
            return libraryLoading ? .waitForLibrary : .nothing(missing: "last played")
        }
        return .lastPlayed(lastPlayedId)
    }
}
