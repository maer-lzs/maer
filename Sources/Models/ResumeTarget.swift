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
    case nothing(missing: Missing)

    /// What a request that found nothing missed. The raw value is the word
    /// the log line names it by.
    enum Missing: String, Equatable, Sendable {
        /// The title Siri or a row named is not on the device.
        case item
        /// The device has no last played title: a fresh device.
        case noLastPlayed = "no last played"
        /// The last played title no longer resolves.
        case lastPlayedNotFound = "last played not found"

        /// What the request says. Each case has its own catalog key, so one
        /// sentence changes without the others.
        var sentence: LocalizedStringResource {
            switch self {
            case .noLastPlayed: "Nothing to continue yet."
            case .lastPlayedNotFound: "Nothing to resume: last played not found"
            case .item: "Nothing to resume: title not found"
            }
        }

        /// The symbol's cause for that sentence: a device without a last
        /// played title is no fault, a title that no longer resolves is one.
        var cause: NoticeCause {
            self == .noLastPlayed ? .nothingYet : .unknown
        }
    }

    /// Nothing continues and nothing waits: the person is told.
    var findsNothing: Bool {
        if case .nothing = self { return true }
        return false
    }

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
            return libraryLoading ? .waitForLibrary : .nothing(missing: .item)
        }
        if hasActivePlayer { return .resumeActive }
        // No pointer and a pointer nothing resolves are two findings: the
        // first is a fresh device, the second a title gone from its source.
        guard let lastPlayedId else {
            return libraryLoading ? .waitForLibrary : .nothing(missing: .noLastPlayed)
        }
        guard lastPlayedKnown else {
            return libraryLoading ? .waitForLibrary : .nothing(missing: .lastPlayedNotFound)
        }
        return .lastPlayed(lastPlayedId)
    }
}
