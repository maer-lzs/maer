// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A link on maer.fm that names one public thing: a podcast episode, a
/// show, a station of the Radio Browser catalog or a free audiobook.
///
/// Everything stands after the `#` (`https://maer.fm/l#1?k=e&f=…`), so the
/// server that answers the page sees only `/l`, never what is shared. The
/// values are a readable query, percent-encoded, and anyone can read what a
/// link names. The identity opens the content in the app; the facts (title,
/// subtitle, audio) are for the page without the app.
///
/// One rule, `offers`, decides what may be shared, and the app asks it
/// again when a link arrives: a link that names a private feed or an
/// address with access opens nothing, whoever builds it.
nonisolated enum SharedLink {
    static let host = "maer.fm"
    static let path = "/l"
    /// The form of the fragment; a link of another form opens nothing.
    static let version = "1"
    /// A fragment longer than this is no link the app builds.
    static let longestFragment = 4096

    /// What a link names.
    enum Content: Equatable, Sendable {
        /// An episode: its feed and its guid as the feed states it.
        case episode(feedURL: String, guid: String, Facts)
        case show(feedURL: String, Facts)
        /// A Radio Browser station by its `stationuuid`.
        case station(uuid: String, Facts)
        /// A free audiobook by its catalog id (`lv:`, `lva:`, `gut:`).
        case book(itemId: String, Facts)

        var facts: Facts {
            switch self {
            case .episode(_, _, let facts), .show(_, let facts), .station(_, let facts), .book(_, let facts):
                return facts
            }
        }
    }

    /// What the page without the app shows. The app opens by the identity
    /// and does not need them.
    struct Facts: Equatable, Sendable {
        var title: String?
        /// The show, the author, or nothing.
        var subtitle: String?
        /// The public audio address: the episode, the stream, the first chapter.
        var audioURL: String?

        init(title: String? = nil, subtitle: String? = nil, audioURL: String? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.audioURL = audioURL
        }
    }

    /// The catalogs whose titles may be shared: books only, music stays out.
    static let bookPrefixes = [FreeCatalog.librivoxPrefix, FreeCatalog.archivePrefix, FreeCatalog.gutenbergPrefix]

    // MARK: - Writing

    /// The link for a content, in a fixed order of keys.
    static func url(for content: Content) -> URL? {
        var pairs: [(String, String?)]
        switch content {
        case .episode(let feedURL, let guid, _): pairs = [("k", "e"), ("f", feedURL), ("g", guid)]
        case .show(let feedURL, _): pairs = [("k", "s"), ("f", feedURL)]
        case .station(let uuid, _): pairs = [("k", "r"), ("i", uuid)]
        case .book(let itemId, _): pairs = [("k", "b"), ("i", itemId)]
        }
        let facts = content.facts
        pairs += [("t", facts.title), ("s", facts.subtitle), ("a", facts.audioURL)]
        let query = pairs.compactMap { key, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return key + "=" + encoded(value)
        }.joined(separator: "&")
        return URL(string: "https://\(host)\(path)#\(version)?\(query)")
    }

    /// Only the unreserved characters stay as they are; everything else,
    /// `&`, `=`, `#`, `+` and space among them, is percent-encoded.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    // MARK: - Reading

    /// What a link names, or nil when it is not a link of this form: another
    /// host or path, a query before the `#`, another version, a key twice, a
    /// kind without its identity. Unknown keys are left alone. Whether the
    /// content may open is `offers`, not this.
    static func read(_ url: URL) -> Content? {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == host,
              url.path == path, url.query == nil,
              let fragment = url.fragment(percentEncoded: true),
              fragment.count <= longestFragment,
              fragment.hasPrefix(version + "?") else { return nil }
        var values: [String: String] = [:]
        for pair in fragment.dropFirst(version.count + 1).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let value = String(parts[1]).removingPercentEncoding else { return nil }
            let key = String(parts[0])
            guard values[key] == nil else { return nil }
            values[key] = value
        }
        func present(_ key: String) -> String? {
            guard let value = values[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        let facts = Facts(title: present("t"), subtitle: present("s"), audioURL: present("a"))
        switch values["k"] {
        case "e":
            guard let feedURL = present("f"), let guid = present("g") else { return nil }
            return .episode(feedURL: feedURL, guid: guid, facts)
        case "s":
            guard let feedURL = present("f") else { return nil }
            return .show(feedURL: feedURL, facts)
        case "r":
            guard let uuid = present("i") else { return nil }
            return .station(uuid: uuid, facts)
        case "b":
            guard let itemId = present("i") else { return nil }
            return .book(itemId: itemId, facts)
        default:
            return nil
        }
    }

    // MARK: - What may be shared

    /// Whether a content may be shared, and whether a link that names it
    /// may open. The feed must not stay home (`staysHome`, the question the
    /// export asks: access in the address, premium, a sign-in, Pinchflat, an
    /// own server); every address in it must be http or https and carry no
    /// access; a station is a Radio Browser uuid; a book is a catalog book
    /// id, never a song address.
    static func offers(_ content: Content, staysHome: (String) -> Bool) -> Bool {
        let addresses: [String]
        switch content {
        case .episode(let feedURL, _, _), .show(let feedURL, _):
            guard !staysHome(feedURL) else { return false }
            addresses = [feedURL]
        case .station(let uuid, _):
            guard UUID(uuidString: uuid) != nil else { return false }
            addresses = []
        case .book(let itemId, _):
            // A song address (`lva:<album>#<index>`) is music, not a book.
            guard let prefix = bookPrefixes.first(where: { itemId.hasPrefix($0) }),
                  itemId.count > prefix.count, !itemId.contains("#") else { return false }
            addresses = []
        }
        return (addresses + [content.facts.audioURL].compactMap { $0 }).allSatisfy(isPublicAddress)
    }

    /// The link a page offers to share: nil when there is no content or
    /// `offers` says no, so the page shows no share button.
    static func shareURL(_ content: Content?, staysHome: (String) -> Bool) -> URL? {
        guard let content, offers(content, staysHome: staysHome) else { return nil }
        return url(for: content)
    }

    /// An http or https address with a host and no access in it.
    static func isPublicAddress(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return false }
        return !PodcastFeedAddress.carriesAccess(raw)
    }

    // MARK: - From the app's own things

    /// The link content of an episode, nil for any episode that is not from
    /// a feed (a server's episode, a local file).
    static func content(episode: PodcastEpisode, feedURL: String, showTitle: String?) -> Content? {
        guard ItemNamespace.isRSS(episode.guid) else { return nil }
        return .episode(feedURL: feedURL, guid: PodcastIdentity.originalGuid(episode.guid),
                        Facts(title: episode.title, subtitle: showTitle, audioURL: episode.audioURL))
    }

    /// The link content of a show from a feed; nil for a server's show.
    static func content(show: PodcastShow) -> Content? {
        guard !ItemNamespace.isABSPodcast(show.id) else { return nil }
        return .show(feedURL: show.feedURL, Facts(title: show.title, subtitle: show.author))
    }

    /// The link content of a Radio Browser station; nil for one entered by hand.
    static func content(station: RadioStation) -> Content? {
        let prefix = ItemNamespace.radioBrowserPrefix
        guard station.id.hasPrefix(prefix) else { return nil }
        return .station(uuid: String(station.id.dropFirst(prefix.count)),
                        Facts(title: station.name, audioURL: station.streamURL))
    }

    /// The link content of a catalog book; nil for any other title.
    static func content(bookId: String, title: String, author: String?, audioURL: String?) -> Content? {
        guard bookPrefixes.contains(where: { bookId.hasPrefix($0) }) else { return nil }
        return .book(itemId: bookId, Facts(title: title, subtitle: author, audioURL: audioURL))
    }

    /// The app's id of a shared station and of a shared episode.
    static func stationId(uuid: String) -> String { ItemNamespace.radioBrowserPrefix + uuid }
    static func episodeId(feedURL: String, guid: String) -> String {
        "rss:\(PodcastIdentity.feedKey(feedURL)):\(guid)"
    }
}
