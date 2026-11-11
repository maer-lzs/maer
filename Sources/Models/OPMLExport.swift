// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Subscriptions as an OPML document. The export
/// counterpart of the importer. Pure builder (tested); no network.
nonisolated enum OPMLExport {
    /// Feeds whose address stays home are EXCLUDED from the export by
    /// default. A shared OPML must never give the access away. Detection:
    /// the caller's one question (`PodcastSubscriptions.staysHome`: premium,
    /// an unreadable sign-in, the person's own server) PLUS the defensive
    /// net of the address itself (a secret parameter, a user or password
    /// before the host) as a second layer. Pure; the count feeds the
    /// visible hint.
    static func partition(shows: [(title: String, feedURL: String)],
                          staysHome: (String) -> Bool) -> (safe: [(title: String, feedURL: String)],
                                                           excluded: [(title: String, feedURL: String)]) {
        var safe: [(title: String, feedURL: String)] = []
        var excluded: [(title: String, feedURL: String)] = []
        for show in shows {
            if staysHome(show.feedURL) || PodcastFeedAddress.carriesAccess(show.feedURL) {
                excluded.append(show)
            } else {
                safe.append(show)
            }
        }
        return (safe, excluded)
    }

    /// One stored entry as the seam carries it out, or nil when the entry
    /// is no state (nothing heard). A finished episode without a duration
    /// holds the sentinel; it goes out as finished with no position, which
    /// the reader turns back into the sentinel. Pure, so the round trip
    /// store ⇒ export ⇒ reader ⇒ rule can be witnessed without a store.
    static func exportedState(entry: [Double], feedURL: String, guid: String,
                              enclosureURL: String?, link: String?, title: String?,
                              duration: Double, archived: Bool = false) -> ForeignListeningState? {
        guard let position = entry.first else { return nil }
        let finished = ProgressMark.reachedEnd(stored: entry, currentDuration: duration)
        guard finished || position > 1 else { return nil }
        return ForeignListeningState(
            feedURL: feedURL,
            episodeGUID: guid,
            enclosureURL: enclosureURL.flatMap { $0.isEmpty ? nil : $0 },
            episodeLink: link,
            episodeTitle: title,
            position: position >= ProgressMark.playedSentinel ? 0 : position,
            duration: duration > 0 ? duration : nil,
            finished: finished,
            stampedAt: ProgressMark.timestamp(entry),
            archived: archived)
    }

    /// The states that belong to the shows being written: a state travels
    /// only with its show, so an excluded premium feed takes its states
    /// out of the file with it. An episode's own address (its enclosure, its
    /// page) that carries access does not travel either; the state goes
    /// without it and is found by its guid.
    static func states(_ states: [ForeignListeningState],
                       for shows: [(title: String, feedURL: String)]) -> [ForeignListeningState] {
        let feeds = Set(shows.map(\.feedURL))
        return states.filter { $0.feedURL.map(feeds.contains) == true }.map { state in
            var kept = state
            if kept.enclosureURL.map(PodcastFeedAddress.carriesAccess) == true { kept.enclosureURL = nil }
            if kept.episodeLink.map(PodcastFeedAddress.carriesAccess) == true { kept.episodeLink = nil }
            return kept
        }
    }

    /// One outline per show: title + xmlUrl (the feed). With states, each
    /// show nests one `podcast-episode` outline per episode that has a
    /// state, in the attribute names Overcast's export uses plus `guid`,
    /// so the one reader reads both files and a file of ours lands on the
    /// ladder's first rung. XML-escaped; shows without a feed URL cannot
    /// round-trip and are skipped, and so are states of shows not written.
    static func document(shows: [(title: String, feedURL: String)],
                         states: [ForeignListeningState] = [],
                         generatedAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: generatedAt)
        let moment = ISO8601DateFormatter()
        moment.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var byFeed: [String: [ForeignListeningState]] = [:]
        for state in states {
            if let feed = state.feedURL { byFeed[feed, default: []].append(state) }
        }
        let outlines = shows
            .filter { !$0.feedURL.isEmpty }
            .map { show in
                let head = #"    <outline type="rss" text="\#(escape(show.title))" xmlUrl="\#(escape(show.feedURL))""#
                guard let episodes = byFeed[show.feedURL], !episodes.isEmpty else { return head + "/>" }
                let nested = episodes.map { state in
                    var attrs = [#"type="podcast-episode""#]
                    if let guid = state.episodeGUID { attrs.append(#"guid="\#(escape(guid))""#) }
                    if let title = state.episodeTitle { attrs.append(#"title="\#(escape(title))""#) }
                    if let enclosure = state.enclosureURL { attrs.append(#"enclosureUrl="\#(escape(enclosure))""#) }
                    if let link = state.episodeLink { attrs.append(#"url="\#(escape(link))""#) }
                    attrs.append(#"progress="\#(Int(state.position.rounded()))""#)
                    attrs.append(#"played="\#(state.finished ? "1" : "0")""#)
                    if state.archived { attrs.append(#"userDeleted="1""#) }
                    if let stamped = state.stampedAt {
                        // Whole milliseconds out, whole milliseconds back in.
                        attrs.append(#"userUpdatedDate="\#(moment.string(from: Date(timeIntervalSince1970: stamped.rounded() / 1000)))""#)
                    }
                    return "      <outline " + attrs.joined(separator: " ") + "/>"
                }.joined(separator: "\n")
                return head + ">\n" + nested + "\n    </outline>"
            }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>Mär subscriptions</title>
            <dateCreated>\(stamp)</dateCreated>
          </head>
          <body>
        \(outlines)
          </body>
        </opml>
        """
    }

    static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
