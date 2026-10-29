// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which Audiobookshelf server the per-book state of this device belongs
/// to. A library id carries no server, so a full load of another server
/// judges the books of the first one gone, and the progress queue hands
/// their unsent stands to whichever server is signed in, whose absence
/// answer drops them. This rule keeps the two apart; a server is named by
/// its normalized address, so the same instance under a new address counts
/// as another server and nothing is cleaned for it.
nonisolated enum ABSServerScope {
    /// What a full library load may do with the per-book state.
    enum Cleanup: Equatable, Sendable {
        case clean
        /// Not this time, with the reason for the line.
        case skip(String)
    }

    /// A full load of `current` cleans only on a device that knew one
    /// server, and only when the last full load came from it. Once a second
    /// server was signed in, a library id of either could be absent from
    /// the other's list, so nothing without a namespace is cleaned until the
    /// id carries its server. No known earlier load (the first start with
    /// this rule) skips once; the caller then remembers `current`.
    static func cleanup(lastFullLoad: String?, current: String?, moreThanOneServer: Bool) -> Cleanup {
        if moreThanOneServer { return .skip("more than one server signed in on this device") }
        guard let current else { return .skip("server unknown") }
        guard let lastFullLoad else { return .skip("no earlier full load known") }
        return lastFullLoad == current ? .clean : .skip("last full load from another server")
    }

    /// What the queue does with one waiting stand.
    enum QueueFate: Equatable, Sendable {
        case send
        /// Sent, but an absence answer keeps it: the signed-in server
        /// changed after it was queued, so the answer may be another
        /// server's.
        case sendKeptOnAbsence
        /// Queued under another server: neither sent nor dropped.
        case wait
    }

    /// The fate of a queued stand of `itemId`. Only a library id is scoped;
    /// an id with a namespace names its source itself. An entry without a
    /// server is from before the rule.
    static func queueFate(itemId: String, entryServer: String?, queuedAt: Double?,
                          current: String?, switchedAt: Double?) -> QueueFate {
        guard ItemNamespace.of(itemId) == nil else { return .send }
        if let entryServer { return entryServer == current ? .send : .wait }
        guard let switchedAt else { return .send }
        return (queuedAt ?? 0) < switchedAt ? .sendKeptOnAbsence : .send
    }

    /// The server a stand of `itemId` is queued under: the signed-in one
    /// for a library id, none for an id with a namespace.
    static func server(of itemId: String, signedIn: String?) -> String? {
        ItemNamespace.of(itemId) == nil ? signedIn : nil
    }
}
