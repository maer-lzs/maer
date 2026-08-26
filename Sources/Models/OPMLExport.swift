// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Subscriptions as an OPML document — the export
/// counterpart of the importer. Pure builder (tested); no network.
nonisolated enum OPMLExport {
    /// Premium/token feeds are EXCLUDED from the export by default — a
    /// shared OPML must never give the access away. Detection: the caller's
    /// premium marking PLUS the defensive
    /// secret-parameter net (token/freebie/auth/key/secret) as a second
    /// layer. Pure; the count feeds the visible hint.
    static func partition(shows: [(title: String, feedURL: String)],
                          isPremium: (String) -> Bool) -> (safe: [(title: String, feedURL: String)],
                                                           excluded: [(title: String, feedURL: String)]) {
        var safe: [(title: String, feedURL: String)] = []
        var excluded: [(title: String, feedURL: String)] = []
        for show in shows {
            if isPremium(show.feedURL) || PodcastSubscriptions.isTokenFeedURL(show.feedURL) {
                excluded.append(show)
            } else {
                safe.append(show)
            }
        }
        return (safe, excluded)
    }

    /// One outline per show: title + xmlUrl (the feed). XML-escaped; shows
    /// without a feed URL cannot round-trip and are skipped.
    static func document(shows: [(title: String, feedURL: String)],
                         generatedAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: generatedAt)
        let outlines = shows
            .filter { !$0.feedURL.isEmpty }
            .map { show in
                #"    <outline type="rss" text="\#(escape(show.title))" xmlUrl="\#(escape(show.feedURL))"/>"#
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
