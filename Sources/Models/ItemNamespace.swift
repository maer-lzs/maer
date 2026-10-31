// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Ids either carry a NAMESPACE (`sub:`, `gut:`, …) or
/// they are library ids. Everything with a namespace belongs to the source that
/// owns it. And an UNKNOWN namespace belongs to nobody, so it must never be
/// sent to the library server.
///
/// This turns the router's rule around: it used to list what goes elsewhere and
/// send the rest to Audiobookshelf. One forgotten entry therefore produced
/// server requests for ids that cannot exist there. Now the fallback is only
/// reached by ids that carry no namespace at all.
nonisolated enum ItemNamespace {
    /// Every namespace the app knows. Library ids (no namespace) are NOT here.
    static let known: Set<String> = {
        var all: Set<String> = ["local:", "abspod:", "rss:", "sub:", "jf:", "radio:", routinePrefix]
        for prefix in FreeCatalog.allPrefixes { all.insert(prefix) }
        return all
    }()

    /// The namespace of an id, or nil when it carries none (= a library id).
    /// Only a LEADING, non-empty scheme counts. A colon inside a path (as
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

    // MARK: - The source questions, asked here and nowhere else

    /// Views and view models ask THESE, never `hasPrefix("<source>:")`
    /// themselves (a fence keeps it so): the spelling of a namespace is
    /// one fact, and it lives in one file. A provider may still check its
    /// own namespace; that is what a provider is.
    static func isRSS(_ itemId: String) -> Bool { itemId.hasPrefix("rss:") }
    static func isABSPodcast(_ itemId: String) -> Bool { itemId.hasPrefix("abspod:") }
    /// A podcast episode of either home, RSS or the Audiobookshelf server.
    static func isPodcastEpisode(_ itemId: String) -> Bool { isRSS(itemId) || isABSPodcast(itemId) }
    static func isSubsonic(_ itemId: String) -> Bool { itemId.hasPrefix("sub:") }
    /// One predicate per known namespace, this one without a caller today:
    /// the next asker finds it here instead of spelling the prefix.
    static func isJellyfin(_ itemId: String) -> Bool { itemId.hasPrefix("jf:") }
    /// The server's own id behind a Jellyfin id of one kind
    /// (`jf:<kind>:<id>`), nil for another kind or namespace. Pure, so a
    /// rule in Models reads it without the provider.
    static func jellyfinId(_ itemId: String, kind: String) -> String? {
        let prefix = "jf:\(kind):"
        guard itemId.hasPrefix(prefix) else { return nil }
        return String(itemId.dropFirst(prefix.count))
    }
    static func isRadio(_ itemId: String) -> Bool { itemId.hasPrefix("radio:") }
    /// The two id forms inside the radio namespace, spelled here with the
    /// namespaces: a community station carries its radio-browser UUID, a
    /// station entered by hand a UUID of its own. The radio model builds
    /// and reads its ids through these.
    static let radioBrowserPrefix = "radio:rb:"
    static let radioManualPrefix = "radio:manual:"
    /// A routine's rule over a show (`RoutineRule`), not a title. A start
    /// turns it into episodes and a list page shows its line
    /// (`RoutinePlayback`); it never reaches a source.
    static let routinePrefix = "rule:"
    static func isRoutineRule(_ itemId: String) -> Bool { itemId.hasPrefix(routinePrefix) }
    static func isLocal(_ itemId: String) -> Bool { itemId.hasPrefix("local:") }
    static func isCatalog(_ itemId: String) -> Bool { FreeCatalog.allPrefixes.contains(where: itemId.hasPrefix) }

    /// The two music servers' namespaces, for the questions that go across
    /// both: a single song, and a download that holds songs.
    static let musicServerNamespaces = ["sub:", "jf:"]

    /// A single song of a music server (`sub:song:…`, `jf:song:…`).
    static func isServerSong(_ itemId: String) -> Bool {
        musicServerNamespaces.contains { itemId.hasPrefix($0 + "song:") }
    }

    /// The server namespace of an album or server playlist, nil for
    /// anything else.
    static func songHolderNamespace(_ itemId: String) -> String? {
        musicServerNamespaces.first { namespace in
            itemId.hasPrefix(namespace + "album:") || itemId.hasPrefix(namespace + "playlist:")
        }
    }

    /// The song id a server gives inside one of its albums or playlists.
    static func serverSongId(namespace: String, rawId: String) -> String { namespace + "song:" + rawId }
}
