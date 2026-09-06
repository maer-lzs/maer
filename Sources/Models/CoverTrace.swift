// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The cover chain's self-report: which pot answered for a picture, how
/// it ended, and how often that same address was asked.
///
/// The reported symptom is "tiles reload their picture every time they
/// scroll back into view". A line that fires only behind the network
/// cannot tell that apart from a cold first visit: both look like one
/// fetch. The attempt number is what separates them, so it travels with
/// every exit of the chain, not just the failing one.
///
/// Pure and Foundation-only so the vocabulary and the tally can be
/// driven by a test; the caller owns the logging and the storage.
nonisolated enum CoverTrace {
    /// Which store answered. `memo` is the session list of addresses
    /// already recognised as a service stand-in; it answers without any
    /// picture at all.
    enum Pot: String {
        case memo
        case thumbnail
        case full
        case network
    }

    /// How the attempt ended. Every exit of the chain has exactly one,
    /// including the ones that were silent before.
    enum Outcome: String {
        case hit
        case offline
        case transport
        case servicePlaceholder = "service-placeholder"
        case undecodable
    }

    /// One line, one attempt. The address stays last so a long URL never
    /// pushes the verdict out of a truncated log view, and it is host and
    /// path ONLY: a cover address carries the server's token in its query
    /// (Subsonic `u`, `t`, `s`; Audiobookshelf `token`), and the line is
    /// public on the device (measured on 29, E84).
    /// `bytes` where the exit knows how much arrived: an answer that does
    /// not decode is a different thing at 3 kB (a picture in a form the
    /// system does not read) than at 700 B (an error page under a picture's
    /// address), and only the number tells them apart.
    static func line(pot: Pot, outcome: Outcome, attempt: Int, url: URL, bytes: Int? = nil) -> String {
        let size = bytes.map { " bytes=\($0)" } ?? ""
        return "COVER pot=\(pot.rawValue) outcome=\(outcome.rawValue) attempt=\(attempt)\(size) \(address(url))"
    }

    /// Host and path of an address, the query dropped.
    static func address(_ url: URL) -> String {
        (url.host ?? "-") + url.path
    }

    /// How often each address has been asked this session. A plain tally,
    /// not a cache: it must keep counting after a hit, otherwise the
    /// repeat case it exists to measure would stop being visible exactly
    /// when the chain starts working.
    struct Counter {
        private var attempts: [URL: Int] = [:]

        init() {}

        /// The number of THIS attempt: one on first sight, then upward.
        mutating func next(for url: URL) -> Int {
            let value = (attempts[url] ?? 0) + 1
            attempts[url] = value
            return value
        }

        /// How many distinct addresses have been asked. The tally grows
        /// with the session; a surface that scrolls far enough would
        /// otherwise hold every cover URL it ever saw with no ceiling.
        var trackedAddresses: Int { attempts.count }

        /// Forgets everything. The caller trims on the same signal the
        /// image caches use, so the tally cannot outgrow them.
        mutating func reset() { attempts.removeAll() }
    }

    /// Above this many distinct addresses the tally is dropped. Chosen
    /// against the thumbnail cache's own capacity (240 previews): a tally
    /// that outlives what the caches can hold measures nothing useful any
    /// more, and each entry is a URL plus an Int.
    static let addressCeiling = 2_000
}
