// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The statistics name what they count, never show a key,
/// keep the duration on the right, and leave out what was barely heard.
struct StatsNamesTests {
    private static func squeezed(_ raw: String) -> String {
        SyncContractFenceTests.stripped(raw)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return squeezed(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8))
    }

    /// The cases live in `Fixtures/Shared/abos/show-names.json`, read by
    /// Swift and Kotlin alike: a show outside the subscriptions finds its
    /// name among the heard, a subscribed one its own, an unknown id none.
    nonisolated static let names = SharedCases.cases("show-names")

    @Test("gemeinsame Faelle: show-names traegt drei Faelle")
    func nameCasesLoaded() {
        #expect(Self.names.count == 3)
    }

    @Test("gemeinsame Faelle: showTitle antwortet je Fall wie die Datei sagt", arguments: names)
    func showTitle(_ c: SharedCase) throws {
        let input = try c.value("input")
        let showId = try #require(input["showId"]?.string
                                  ?? input["showIdFromFeed"]?.string.map { "rss:\(PodcastSubscriptions.feedKey($0))" })
        let shows = try #require(input["shows"]?.array).map { show in
            PodcastShow(id: "feed:\(PodcastSubscriptions.feedKey(show["idFromFeed"]?.string ?? ""))",
                        title: show["title"]?.string ?? "", author: nil, artworkURL: nil,
                        description: nil, feedURL: show["feedURL"]?.string ?? "", episodes: [])
        }
        let heard = try #require(input["heard"]?.array).map {
            (feedURL: $0["feedURL"]?.string ?? "", title: $0["title"]?.string ?? "")
        }
        #expect(PodcastSubscriptions.showTitle(for: showId, in: shows, heard: heard) == c["expect"]?.string, "\(c.slug)")
    }

    @Test("GT-25: ein Sender, der aus Wieder hoeren gefallen ist, behaelt seinen Namen aus Meistgespielt")
    func aStationOutOfListenAgainKeepsItsName() {
        let name = "stats-names-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let station = RadioStation(id: "radio:rb:960e", name: "Deutschlandfunk", streamURL: "https://s/dlf")
        RadioStore.recordPlay(station, defaults: defaults)
        #expect(RadioStore.station(forId: station.id, defaults: defaults) == nil,
                "Wieder hoeren kennt ihn nicht, das ist der gemessene Fall")
        #expect(RadioStore.stationName(forId: station.id, defaults: defaults) == "Deutschlandfunk")
        #expect(RadioStore.stationName(forId: "radio:rb:none", defaults: defaults) == nil)
    }

    @Test("GT-26: unter einer Minute steht nichts in meistgehoert und nimmt keinen Platz")
    @MainActor func nothingUnderAMinute() {
        #expect(StatsView.shortest == 60)
        // The limit leaves room, so only the floor can keep the 59 out.
        let shows = ListeningByClass.top(["a": 59, "b": 60, "c": 0, "d": 500], limit: 3,
                                         atLeast: Double(StatsView.shortest))
        #expect(shows.map(\.id) == ["d", "b"])
        let stats = ListeningStatsStore(carrier: KeyValueStatsCarrier(store: InMemoryCloudStore()))
        for (id, seconds) in [("radio:rb:a", 20), ("radio:rb:b", 3600), ("radio:rb:c", 60)] {
            stats.addSeconds(seconds, itemId: id)
        }
        #expect(stats.topItems(limit: 3, atLeast: StatsView.shortest, matching: ListeningClasses.isLive)
            .map(\.id) == ["radio:rb:b", "radio:rb:c"],
                "der Sender mit 0 Min. steht nicht da und verdraengt keinen")
    }

    @Test("GT-25/26: die Seite zeigt nie eine Kennung, die Dauer steht in einer Zeile rechts, beide Listen tragen die Minute")
    func thePageWiresTheRules() throws {
        let view = try Self.source("Sources/Views/StatsView.swift")
        #expect(!view.contains("?? entry.id") && !view.contains("?? showId"), "keine Kennung als Ersatz")
        #expect(view.contains("PodcastShowSources.knownTitle(forShowId: entry.id) ?? String(localized: \"Unknown Show\")"))
        #expect(view.contains("RadioStore.stationName(forId: entry.id) ?? String(localized: \"Unknown Station\")"))
        #expect(view.components(separatedBy: "rankedRow(").count - 1 == 3, "beide Listen und die Definition")
        #expect(view.contains("limit: Self.topLimit, atLeast: Double(Self.shortest))"))
        #expect(view.contains("stats.topItems(limit: Self.topLimit, atLeast: Self.shortest,"))
        #expect(view.contains("StatsRankedRow(name: name, duration: formatted(seconds))"))
        #expect(view.contains("time.fixedSize()") && view.contains("if typeSize.isAccessibilitySize {"),
                "neben dem Namen haelt die Dauer ihre Breite, in AX-Groessen steht sie rechts darunter")
        let sources = try Self.source("Sources/ViewModels/PodcastShowSources.swift")
        #expect(sources.contains("PodcastListenLog.shared.entries.values.map")
                && sources.contains("BrowsedEpisodes.shared.allListened().map")
                && sources.contains("PodcastSubscriptions.showTitle(for: showId, in: ownedShows(), heard: heard)"),
                "alle vier Bestaende tragen den Namen")
    }
}
#endif
