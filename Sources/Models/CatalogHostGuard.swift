// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The politeness distance belongs to the HOST, not to our surfaces.
///
/// Measured on the device: Old Time Radio, LibriVox and the archive
/// audiobooks fell on `-1004` within the same minute while Gutenberg
/// loaded normally next to them; the network was healthy, one host had
/// cut us off. Three of our sources are ONE archive.org, and the
/// per-source distance let each of them keep knocking on a door the
/// other two had just been thrown out of.
///
/// Pure and injectable (clock as a parameter), because a rule about
/// time is otherwise untestable.
nonisolated enum CatalogHostGuard {
    /// How long a host stays untouched after it refused us.
    static let blockSeconds: TimeInterval = 30

    /// The host of a query, as far as this rule cares: everything that
    /// speaks to archive.org counts as ONE, no matter which collection
    /// our surface calls it.
    static func host(forSurface surface: String) -> String {
        switch surface {
        case "gutenberg": return "gutendex.com"
        default: return "archive.org"
        }
    }

    static func isBlocked(_ host: String, since: [String: Date], now: Date) -> Bool {
        guard let last = since[host] else { return false }
        return now.timeIntervalSince(last) < blockSeconds
    }

    /// Thrown instead of a request while a host is inside its distance.
    /// Named, so the log can tell a kept distance from a fresh refusal
    /// and a surface says "not right now" instead of blaming the network.
    struct Paused: Error, Sendable {
        let host: String
    }

    /// Only a REFUSAL earns a host its distance: the connection was not
    /// accepted or was dropped. A timeout, a bad status or a decode
    /// failure says nothing about the host being overrun, and a
    /// cancellation says nothing at all.
    static func isRefusal(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .networkConnectionLost: return true
        default: return false
        }
    }
}
