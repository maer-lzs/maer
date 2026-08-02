// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Foundation
import Testing
@testable import ABSPlayer

/// a449534: the pure pieces of the settings consolidation — suggestion
/// languages (effective/storefront/PI parameter), the iTunes chart URL the
/// language wiring hangs off, and the OPML export document.
struct SettingsConsolidationTests {

    @Test("Suggestion languages: stored beats locale; locale beats en-fallback")
    func effective() {
        #expect(SuggestionLanguages.effective(stored: ["de", "en"], localeLanguage: "fr") == ["de", "en"])
        #expect(SuggestionLanguages.effective(stored: [], localeLanguage: "fr") == ["fr"])
        #expect(SuggestionLanguages.effective(stored: nil, localeLanguage: nil) == ["en"])
    }

    @Test("Storefront map: language → representative storefront; PI gets a real lang list")
    func storefronts() {
        #expect(SuggestionLanguages.storefront(for: "de") == "de")
        #expect(SuggestionLanguages.storefront(for: "EN") == "us")
        #expect(SuggestionLanguages.storefront(for: "pt") == "br")
        #expect(SuggestionLanguages.storefront(for: "xx") == "xx")
        #expect(SuggestionLanguages.podcastIndexLangParameter(["de", "EN"]) == "de,en")
    }

    @Test("Chart URL: storefront + genre land in the path (the language wiring's anchor)")
    func chartURL() {
        #expect(ITunesDirectory.chartURL(storefront: "de", genreId: 1303, limit: 30)?.absoluteString
                == "https://itunes.apple.com/de/rss/toppodcasts/limit=30/genre=1303/json")
        #expect(ITunesDirectory.chartURL(storefront: "us", genreId: nil, limit: 40)?.absoluteString
                == "https://itunes.apple.com/us/rss/toppodcasts/limit=40/json")
    }

    @Test("OPML export: outlines per show, XML-escaped, feed-less shows skipped")
    func opml() {
        let doc = OPMLExport.document(
            shows: [(title: "A & B \"Show\"", feedURL: "https://f.example/a?x=1&y=2"),
                    (title: "No Feed", feedURL: "")],
            generatedAt: Date(timeIntervalSince1970: 1_784_600_000))
        #expect(doc.contains(#"text="A &amp; B &quot;Show&quot;""#))
        #expect(doc.contains(#"xmlUrl="https://f.example/a?x=1&amp;y=2""#))
        #expect(!doc.contains("No Feed"))
        #expect(doc.contains("<opml version=\"2.0\">"))
        // Round-trip sanity: the export parses as XML.
        #expect(XMLParser(data: Data(doc.utf8)).parse())
    }
}
#endif
