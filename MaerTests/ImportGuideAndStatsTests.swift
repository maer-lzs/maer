// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Four faults of the import guides and the statistics. A guide's title
/// that is a word and not a brand is translated; Spotify, which gives
/// nothing to import, is no guide. The shows of the statistics count from
/// the same measured seconds as Total, so their sum never stands above it,
/// and a show nobody can name is no row.
struct ImportGuideAndStatsTests {
    // MARK: The guides

    /// The titles that are names of apps and stay as they are.
    static let brands: Set<String> = ["Apple Podcasts", "Overcast", "AntennaPod", "Pocket Casts"]

    @Test("a title that is a word comes from the catalog, translated; the others are brands")
    func titlesAreTranslated() throws {
        for guide in ImportGuide.allCases where guide != .otherOPML {
            #expect(Self.brands.contains(guide.title), "\(guide.title) is no brand and not translated")
        }
        let entries = try StringCatalogOrderTests.entries()
        let languages = entries["Other apps (OPML)"]?["localizations"] as? [String: Any] ?? [:]
        for language in ["de", "fr"] {
            let unit = (languages[language] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect(unit?["state"] as? String == "translated", "\(language)")
            #expect((unit?["value"] as? String ?? "Other apps (OPML)") != "Other apps (OPML)", "\(language)")
        }
    }

    /// The titles a guide's `title` returns as written: every
    /// `return "…"` between `var title` and the next `var`.
    static func bareTitles(in source: String) -> [String] {
        guard let start = source.range(of: "var title: String") else { return [] }
        let rest = source[start.upperBound...]
        let body = rest.range(of: "\n    var ").map { rest[..<$0.lowerBound] } ?? rest
        let pattern = try? NSRegularExpression(pattern: #"return "([^"]*)""#)
        let text = String(body)
        return pattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        } ?? []
    }

    @Test("Fence: every title of the guides is looked up in the catalog or is a brand", .needsTheSources)
    func titleIsLookedUp() throws {
        let guides = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Models/ImportGuides.swift"), encoding: .utf8))
        let bare = Self.bareTitles(in: guides)
        #expect(bare.count == Self.brands.count, "the titles were read: \(bare)")
        #expect(Set(bare).subtracting(Self.brands).isEmpty, "a title that is a word stands as written: \(bare)")
        #expect(guides.contains("String(localized: \"Other apps (OPML)\")"))
        // Counter probe: the fence sees a word written as a title.
        let probe = """
            var title: String {
                switch self {
                case .overcast: return "Overcast"
                case .otherOPML: return "Other apps (OPML)"
                }
            }
            var action: Action {
            """
        #expect(Set(Self.bareTitles(in: probe)).subtracting(Self.brands) == ["Other apps (OPML)"])
    }

    @Test("Spotify is no guide: five sources, and its sentence left the catalog")
    func spotifyIsGone() throws {
        #expect(ImportGuide.allCases.map(\.rawValue) == ["applePodcasts", "overcast", "antennaPod", "pocketCasts", "otherOPML"])
        let entries = try StringCatalogOrderTests.entries()
        #expect(entries.keys.allSatisfy { !$0.hasPrefix("Spotify offers no export") })
    }

    // MARK: The statistics

    /// A day of listening as the player's tick writes it: each second to
    /// the day and to the title.
    static func listened(_ items: [String: Int]) -> ListeningStatsData {
        var data = ListeningStatsData()
        for (item, seconds) in items {
            data.secondsPerDay["2026-11-25", default: 0] += seconds
            data.secondsPerItem[item, default: 0] += seconds
        }
        return data
    }

    @Test("the shows count from the measured seconds: their sum stands at most at Total, a stored position alone counts nothing")
    func sumAtMostTotal() {
        var data = Self.listened(["rss:a:1": 3_600, "rss:a:2": 1_800, "abspod:b:9": 600, "sub:song:1": 900])
        // Another device's radio counts in Total and is no show.
        data.secondsPerDay["2026-11-24", default: 0] += 7_200
        let total = data.secondsPerDay.values.reduce(0, +)
        let shows = ListeningByClass.shows(seconds: data.secondsPerItem,
                                           showId: AppStorageKeys.podcastShowId(forEpisodeId:))
        #expect(shows == ["rss:a": 5_400, "abspod:b": 600])
        #expect(shows.values.reduce(0, +) <= Double(total))
        // The positions of the old way said 176 hours for a show heard
        // elsewhere; they are no listening here and count nothing.
        let positions: [String: [Double]] = ["rss:c:1": [633_600, 700_000]]
        #expect(ListeningByClass.shows(positions: positions, showId: AppStorageKeys.podcastShowId(forEpisodeId:))["rss:c"] == 633_600,
                "the old way, still the recommendations' seed")
        #expect(shows["rss:c"] == nil)
    }

    @Test("a show nobody can name is no row and takes no place among the five; one its episode names stands with that name")
    func unnamedIsNoRow() {
        let seconds: [String: Double] = ["rss:gone": 633_600, "rss:a": 7_200, "rss:b": 3_600, "abspod:c": 1_800,
                                         "rss:d": 900, "rss:e": 600, "rss:f": 120]
        let names = ["rss:a": "Alpha", "rss:b": "Beta", "rss:d": "Delta", "rss:e": "Echo", "rss:f": "Foxtrot"]
        let episodeNames = ["abspod:c": "Charlie"]
        let rows = ListeningByClass.namedTop(seconds, limit: 5, atLeast: 60) { id in
            names[id] ?? episodeNames[id]
        }
        #expect(rows.map(\.title) == ["Alpha", "Beta", "Charlie", "Delta", "Echo"])
        #expect(!rows.contains { $0.id == "rss:gone" })
        #expect(ListeningByClass.namedTop(["rss:a": 30], limit: 5, atLeast: 60) { _ in "Alpha" }.isEmpty,
                "below a minute stays out")
    }

    @Test("Fence: the statistics ask the measured seconds and name a show from its episode too", .needsTheSources)
    func statsAskTheMeasure() throws {
        let view = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Views/StatsView.swift"), encoding: .utf8))
        #expect(!view.contains("ListeningStore.positions()"), "the shows still sum stored positions")
        #expect(view.contains("let seconds = stats.itemSeconds(matching: ItemNamespace.isPodcastEpisode)")
                && view.contains("ListeningByClass.shows(seconds: seconds,"))
        #expect(view.contains("ListeningByClass.namedTop("))
        #expect(!view.contains("\"Unknown Show\""), "a show without a name still stands as one")
        // Over Mär Sync the seconds of every title travel, over iCloud only
        // the stations': the footer names no device.
        #expect(view.contains("Text(\"Measured while you listen in Mär, from when it began counting.\")"))
        let sources = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/ViewModels/PodcastShowSources.swift"), encoding: .utf8))
        #expect(sources.contains("static func statsTitle(forShowId"))
    }
}
#endif
