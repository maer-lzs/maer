// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// c3ab12e Strukturfix: ids either carry a NAMESPACE (`sub:`, `gut:`, …) or
/// they are library ids. Everything with a namespace belongs to the source that
/// owns it — and an UNKNOWN namespace belongs to nobody, so it must never be
/// sent to the library server.
///
/// This turns the router's rule around: it used to list what goes elsewhere and
/// send the rest to Audiobookshelf. One forgotten entry therefore produced
/// server requests for ids that cannot exist there. Now the fallback is only
/// reached by ids that carry no namespace at all.
nonisolated enum ItemNamespace {
    /// Every namespace the app knows. Library ids (no namespace) are NOT here.
    static let known: Set<String> = {
        var all: Set<String> = ["local:", "abspod:", "rss:", "sub:", "jf:", "radio:"]
        for prefix in FreeCatalog.allPrefixes { all.insert(prefix) }
        return all
    }()

    /// The namespace of an id, or nil when it carries none (= a library id).
    /// Only a LEADING, non-empty scheme counts — a colon inside a path (as
    /// local file ids can have) is not a namespace.
    static func of(_ itemId: String) -> String? {
        guard let colon = itemId.firstIndex(of: ":") else { return nil }
        let scheme = itemId[itemId.startIndex..<colon]
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return String(itemId[itemId.startIndex...colon])
    }

    /// True when the id belongs to a source the app knows.
    static func isKnown(_ itemId: String) -> Bool {
        guard let ns = of(itemId) else { return true }   // library id
        return known.contains(ns)
    }

    /// The guard that would have prevented the lockout: an id from an unknown
    /// namespace must not produce a request to the library server.
    static func mayReachLibraryServer(_ itemId: String) -> Bool {
        of(itemId) == nil
    }
}
