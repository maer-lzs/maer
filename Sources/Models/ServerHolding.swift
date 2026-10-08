// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether a show lies on Audiobookshelf, as this device can answer it
/// now. Podcasts on Audiobookshelf and from RSS share their listening
/// state, so the two sources hold a show exclusively: a show held there
/// gets no local subscription.
nonisolated enum ServerHolding: Equatable, Sendable {
    /// Audiobookshelf is off, or its shows were read and this one is not
    /// among them.
    case notThere
    /// Audiobookshelf holds the show, under this title.
    case held(title: String)
    /// Audiobookshelf is on and its shows were not read in this session:
    /// no answer, which is not "not there".
    case unread

    /// The answer for `feedKey`, from the server's shows by feed key and
    /// whether they were read. A show already known is held, read or not.
    static func of(feedKey: String, read: Bool, serverTitles: [String: String]) -> ServerHolding {
        if let title = serverTitles[feedKey] { return .held(title: title) }
        return read ? .notThere : .unread
    }
}
