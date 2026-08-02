// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// a449534 point 5: subscriptions as an OPML document — the export
/// counterpart of the importer. Pure builder (tested); no network.
nonisolated enum OPMLExport {
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
