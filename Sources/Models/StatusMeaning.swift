// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The one place a non-2xx status becomes a meaning. A caller that books,
/// words or refuses on a status reads the meaning here, never the number
/// again; the raw status travels beside it wherever it is kept.
///
/// Sits BEHIND the retry ladder. `RequestRetryPolicy` and the gpodder
/// client read 429 and 5xx as "wait and ask again", and only what survives
/// the ladder is a meaning; a fence holds that the ladder never asks here.
/// Clients whose answers mean something else (a body that carries the
/// error, a 404 that is "not yet", a 412 that is "stale") keep their own
/// sentences and stand in the same fence as a stock with their reasons.
nonisolated enum StatusMeaning: Equatable, Sendable {
    /// 401 or 403: credentials, or a block on this network. Not "gone", not "down".
    case signIn
    /// 404 or 410: the address names nothing. The only clean "there is none".
    case notFound
    /// 429: the host asked for a pause. Says nothing about what was asked for.
    case throttled
    /// Any other non-2xx: the host's problem, the number says which.
    case server

    static func from(status: Int) -> StatusMeaning {
        switch status {
        case 401, 403: return .signIn
        case 404, 410: return .notFound
        case 429: return .throttled
        default: return .server
        }
    }

    /// Whether the host has said "there is none". Only this may be written
    /// down as a clean no; a refusal, a pause and a server error are not
    /// findings about the thing that was asked for.
    var isAbsence: Bool { self == .notFound }

    /// Whether a status is the host failing (5xx), as against any other
    /// refusal of the request that `server` also carries. Asking again can
    /// get another answer from a failing host, never from a refusal.
    static func isServerFailure(status: Int) -> Bool { (500...599).contains(status) }
}
