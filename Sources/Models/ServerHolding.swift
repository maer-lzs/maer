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

    /// What a local subscription does while Audiobookshelf is unread.
    enum WhileUnread: Equatable, Sendable {
        /// The person asked for this feed: subscribed here, noted for the
        /// next read.
        case subscribeNoted
        /// A mechanism asked (gpodder, Pinchflat, the cloud, an import):
        /// nothing subscribed, a later attempt asks again.
        case setOut
    }

    static func whileUnread(byPerson: Bool) -> WhileUnread {
        byPerson ? .subscribeNoted : .setOut
    }

    /// What the next read does with a show subscribed while the server was
    /// unread.
    enum Settle: Equatable, Sendable {
        /// The server does not hold it: the note goes, the subscription stays.
        case noteGoes
        /// Still unread: everything stays for the next read.
        case waits
        /// The server holds it and every state found its episode there: the
        /// states went over, the local subscription goes (the two sources
        /// hold a show exclusively).
        case handOver
        /// The server holds it but a state found no episode there: the local
        /// subscription stays, so nothing heard is lost.
        case keepsLocal
    }

    static func settle(_ holding: ServerHolding, everyStateBridged: Bool) -> Settle {
        switch holding {
        case .notThere: .noteGoes
        case .unread: .waits
        case .held: everyStateBridged ? .handOver : .keepsLocal
        }
    }
}
