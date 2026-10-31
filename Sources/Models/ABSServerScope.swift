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
    /// The one name of a server: the address without a user, a password,
    /// a query or a fragment (`KnownServers.normalized` strips the
    /// credentials), the scheme and the host in small letters, without the
    /// scheme's default port and a trailing slash. Every place that stores
    /// or compares a server asks here, so one server under two spellings
    /// stays one, and no secret reaches the settings.
    static func identity(of raw: String) -> String {
        let text = KnownServers.normalized(raw)
        guard var components = URLComponents(string: text), let host = components.host else { return text }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = host.lowercased()
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        var name = components.string ?? text
        while name.hasSuffix("/") { name.removeLast() }
        return name
    }

    /// Whether a second server was ever signed in on this device, by the
    /// register of servers that worked (`registered`, the Audiobookshelf
    /// addresses of `KnownServers`). A build before the one name compared
    /// raw addresses, so another spelling of the same server set the mark
    /// `absMoreThanOneServer`. The register was there before the mark, every
    /// sign-in that could set it wrote its address there first, and it never
    /// empties itself: when all its entries are one server and that is the
    /// one signed in, no second one was. An empty register, a second name or
    /// no server signed in keep the mark. An address the person took out of
    /// the register by hand takes its evidence with it.
    static func secondServerShown(registered: [String], signedIn: String?) -> Bool {
        guard let signedIn else { return true }
        return Set(registered.map(identity(of:))) != [identity(of: signedIn)]
    }

    /// What a full library load may do with the per-book state.
    enum Cleanup: Equatable, Sendable {
        case clean
        /// Only the ids `current` owns (`ItemOwners`): the device knew more
        /// than one server.
        case cleanOwned
        /// Not this time, with the reason for the line.
        case skip(String)
    }

    /// A full load of `current` cleans every absent library id only on a
    /// device that knew one server, and only when the last full load came
    /// from it. Once a second server was signed in, a library id of either
    /// could be absent from the other's list, so a load cleans only the ids
    /// the register says are its own; an id without an owner stays. No
    /// known earlier load (the first start with this rule) skips once; the
    /// caller then remembers `current`.
    static func cleanup(lastFullLoad: String?, current: String?, moreThanOneServer: Bool) -> Cleanup {
        guard let current else { return .skip("server unknown") }
        if moreThanOneServer { return .cleanOwned }
        guard let lastFullLoad else { return .skip("no earlier full load known") }
        return identity(of: lastFullLoad) == identity(of: current) ? .clean : .skip("last full load from another server")
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
        if let entryServer { return identity(of: entryServer) == current.map(identity(of:)) ? .send : .wait }
        guard let switchedAt else { return .send }
        return (queuedAt ?? 0) < switchedAt ? .sendKeptOnAbsence : .send
    }

    /// The server a stand of `itemId` is queued under: the signed-in one
    /// for a library id, none for an id with a namespace.
    static func server(of itemId: String, signedIn: String?) -> String? {
        ItemNamespace.of(itemId) == nil ? signedIn.map(identity(of:)) : nil
    }
}
