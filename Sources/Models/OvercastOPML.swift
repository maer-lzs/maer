// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The one OPML reader: plain subscription lists AND Overcast's extended
/// export, which nests `podcast-episode` outlines under each feed with
/// the listening state per episode.
///
/// Pure and Foundation-only (`XMLParser` is Foundation), so the source
/// watch builds it on a plain Linux toolchain. Reading a file, showing a
/// preview and applying states live elsewhere; this only turns bytes
/// into values.
///
/// Overcast's episode attributes, as measured on its export format:
/// `enclosureUrl` (the audio), `url` (the episode's web link),
/// `title`, `played` ("1"), `progress` (seconds), `userUpdatedDate`
/// (ISO 8601). No RSS GUID; the adopter's ladder therefore reaches the
/// episode through the enclosure or the link. This app's own export
/// mirrors the same attributes and adds `guid`, so a file that comes
/// back lands on the first rung.
nonisolated enum OvercastOPML {
    /// Feeds in file order; states empty for a plain OPML, which is then
    /// exactly the subscription import. nil when the XML is not
    /// well-formed: a partial list from a broken file must fail visibly,
    /// never import silently.
    static func parse(_ data: Data) -> ForeignLibrary? {
        let reader = Reader()
        return reader.parse(data)
    }

    /// Overcast writes `2023-05-01T12:00:00-00:00`; the plain ISO form and
    /// one with fractional seconds are accepted too. nil for anything else,
    /// and then the state has no moment and may only fill.
    static func momentMs(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        // Whole milliseconds: the form carries no more, and a fraction
        // from floating point must never decide who is newer.
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return (date.timeIntervalSince1970 * 1000).rounded() }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw).map { ($0.timeIntervalSince1970 * 1000).rounded() }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        private var feedURLs: [String] = []
        private var feedTitles: [String: String] = [:]
        private var states: [ForeignListeningState] = []
        /// The feed the current episode outlines belong to.
        private var feedStack: [String] = []

        func parse(_ data: Data) -> ForeignLibrary? {
            let parser = XMLParser(data: data)
            parser.delegate = self
            guard parser.parse() else { return nil }
            return ForeignLibrary(feedURLs: feedURLs, states: states, feedTitles: feedTitles)
        }

        func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attrs: [String: String]) {
            guard el == "outline" else { return }
            if let url = attrs["xmlUrl"] ?? attrs["xmlURL"], !url.isEmpty {
                feedURLs.append(url)
                if let title = attrs["text"] ?? attrs["title"], !title.isEmpty { feedTitles[url] = title }
                feedStack.append(url)
                return
            }
            // Any outline WITHOUT a feed address is a nesting level: a
            // folder in a plain OPML, or an episode in the extended one.
            feedStack.append(feedStack.last ?? "")
            guard attrs["type"] == "podcast-episode", let feed = feedStack.last, !feed.isEmpty else { return }
            let progress = attrs["progress"].flatMap(Double.init) ?? 0
            // `guid` is this app's own attribute on its export; Overcast
            // writes none, and the ladder then starts at the enclosure.
            states.append(ForeignListeningState(
                feedURL: feed,
                episodeGUID: attrs["guid"].flatMap { $0.isEmpty ? nil : $0 },
                enclosureURL: attrs["enclosureUrl"].flatMap { $0.isEmpty ? nil : $0 },
                episodeLink: attrs["url"].flatMap { $0.isEmpty ? nil : $0 },
                episodeTitle: attrs["title"].flatMap { $0.isEmpty ? nil : $0 },
                position: max(progress, 0),
                finished: attrs["played"] == "1" || attrs["userDeleted"] == "1",
                stampedAt: OvercastOPML.momentMs(attrs["userUpdatedDate"]),
                archived: attrs["userDeleted"] == "1"))
        }

        func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            guard el == "outline", !feedStack.isEmpty else { return }
            feedStack.removeLast()
        }
    }
}
