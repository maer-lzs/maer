// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// What came after the order of the Podcasts tab: the titles of the two
/// switches of the subscriptions as decided; the footer of the
/// shows' statistics true for each carrier (over iCloud only this
/// device's titles count); the measured seconds read once and grouped by
/// one rule; a work without movement numbers ends; the guide page without
/// its dead branch.
struct SliceTwoFollowUpTests {
    static func source(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    static let titles: [(key: String, de: String, fr: String)] = [
        ("Show premium feeds in the subscription list", "Premium-Feeds in der Aboliste zeigen",
         "Afficher les flux premium dans la liste des abonnements"),
        ("Show Pinchflat feeds in the subscription list", "Pinchflat-Feeds in der Aboliste zeigen",
         "Afficher les flux Pinchflat dans la liste des abonnements"),
    ]

    @Test("the two switches carry the decided titles, in English, German and French", .needsTheSources)
    func switchTitles() throws {
        let fold = try Self.source("Sources/Views/Podcasts/PodcastSubscriptionFoldSection.swift")
        #expect(!fold.contains("like other feeds"), "the old titles stand")
        let entries = try StringCatalogOrderTests.entries()
        for title in Self.titles {
            #expect(fold.contains("Label(\"\(title.key)\""), "\(title.key) is no switch title")
            let languages = entries[title.key]?["localizations"] as? [String: Any] ?? [:]
            for (language, value) in [("de", title.de), ("fr", title.fr)] {
                let unit = (languages[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                #expect(unit?["value"] as? String == value && unit?["state"] as? String == "translated", "\(language): \(title.key)")
            }
        }
        #expect(entries["Premium like other feeds"] == nil && entries["Pinchflat like other feeds"] == nil)
    }

    @Test("the shows' seconds travel over Mär Sync and not over iCloud, so the footer names this device only there")
    func footerPerCarrier() {
        #expect(ListeningStatsSync.itemsTravel(hasRoomLimit: false), "Mär Sync carries every title's seconds")
        #expect(!ListeningStatsSync.itemsTravel(hasRoomLimit: true), "iCloud carries only the stations'")
    }

    @Test("Fence: the statistics read the measured seconds once, group them by the rule and say per carrier where they count", .needsTheSources)
    func statsReadOnce() throws {
        let view = try Self.source("Sources/Views/StatsView.swift")
        #expect(view.components(separatedBy: "stats.itemSeconds(").count - 1 == 1, "the seconds are read more than once")
        #expect(view.contains("ListeningByClass.episodesByShow("))
        #expect(view.contains("if stats.itemsTravel {"))
        #expect(view.contains("Text(\"Measured while you listen in Mär on this device, from when it began counting.\")"))
        let entries = try StringCatalogOrderTests.entries()
        let key = "Measured while you listen in Mär on this device, from when it began counting."
        let de = ((entries[key]?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(de?["state"] as? String == "translated")
        let model = try Self.source("Sources/Models/ListeningByClass.swift")
        #expect(!model.contains("The recommendation seed and the statistics ask the same question, so they"),
                "the comment still says both ask the same function")
    }

    @Test("the episodes of each show, grouped once")
    func episodesByShow() {
        let grouped = ListeningByClass.episodesByShow(["rss:a:1", "rss:a:2", "abspod:b:9", "sub:song:1"],
                                                      showId: AppStorageKeys.podcastShowId(forEpisodeId:))
        #expect(grouped.mapValues { Set($0) } == ["rss:a": ["rss:a:1", "rss:a:2"], "abspod:b": ["abspod:b:9"]])
    }

    @Test("a work whose movements carry no number ends after each; nothing follows by guess")
    func noNumberEnds() {
        struct R { let id: String; let title: String }
        let items = [R(id: "1", title: "Suite in D - Allegro"), R(id: "2", title: "Suite in D - Adagio")]
        #expect(MusopenOrder.nextMovement(after: "1", in: items, id: \.id, title: \.title,
                                          composer: { _ in "Johann Sebastian Bach" }, performer: { _ in nil }) == nil)
    }

    @Test("Fence: the guide page has no branch for a guide without steps", .needsTheSources)
    func noDeadBranch() throws {
        let page = try Self.source("Sources/Views/NextStepsView.swift")
        #expect(!page.contains("} else if let note = Self.noteText(guide.notes) {"))
    }
}
#endif
