// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A leftover of the test harness is never a person's choice: it does not
/// travel out, it is not adopted, and when the pot still carries one it
/// leaves both devices.
struct HarnessSeedFenceTests {
    @Test("Die Seed-Kennungen des Harness sind erkennbar, die echten Kennungen nicht")
    func seedIdsAreRecognised() {
        for id in ["radio:manual:seed-1", "radio:manual:seed-2", "radio:rb:seed-pop-1",
                   "sub:album:seed-3", "sub:song:seed-song-1", "lva:seed-classic-2",
                   "lv:seed-book", "rss:seed:ep-1", "seed-book-1", "seed-playlist-2",
                   "seed-artist-1", "seed-show", "filler-show-4"] {
            #expect(UserChoiceCatalog.isHarnessSeed(id: id), "\(id) is a harness leftover")
        }
        // Real ids of the sources, none of them a seed.
        for id in ["radio:manual:swr3", "radio:rb:1a2b3c", "sub:album:1234",
                   "rss:9f8e7d:https://example.org/ep/7", "lva:mobydick_1006_librivox",
                   "abs:0f1e2d", "jam:998877", "seeds-of-change", "Seedorf Radio"] {
            #expect(!UserChoiceCatalog.isHarnessSeed(id: id), "\(id) is a real id")
        }
    }

    @Test("Die Muster sind verankert: eine echte Adresse mit seed im Pfad ist kein Seed")
    func markersAreAnchored() {
        // The consequence of the question is a DELETION, so a marker
        // matched anywhere inside an id would drop a real stand. An rss id
        // carries the whole episode address.
        for real in ["rss:9f8e:https://example.org/seed-book-club/ep1",
                     "rss:1a2b:https://podcast.example/seed-show-notes/42",
                     "rss:3c4d:https://example.net/filler-show-archive/7",
                     "sub:album:my-seed-book",
                     // A hand-entered station is `radio:manual:<UUID>`
                     // (`RadioMapping.manualStation`), so a station NAMED
                     // "Seed of Life FM" never carries the name in its id.
                     "radio:manual:\(UUID().uuidString)",
                     "lva:the_seed_book_1006_librivox"] {
            #expect(!UserChoiceCatalog.isHarnessSeed(id: real), "\(real) is a real id, never a seed")
        }
        // And the anchored forms still are seeds.
        for seed in ["radio:manual:seed-2", "rss:seed:ep-1", "sub:album:seed-3",
                     "lva:seed-classic-2", "seed-book-1", "filler-show-4"] {
            #expect(UserChoiceCatalog.isHarnessSeed(id: seed), "\(seed) is a harness leftover")
        }
    }

    @Test("Der Wahl-Schluessel traegt dieselbe Frage: die Familie davor wird abgezogen, der Anker bleibt")
    func theCloudKeyAsksTheSameQuestion() {
        #expect(UserChoiceCatalog.isHarnessSeed(cloudKey: UserChoiceCatalog.favoritePrefix + "radio:manual:seed-2"))
        #expect(UserChoiceCatalog.isHarnessSeed(cloudKey: UserChoiceCatalog.recentStationPrefix + "radio:rb:seed-pop-1"))
        #expect(!UserChoiceCatalog.isHarnessSeed(cloudKey: UserChoiceCatalog.favoritePrefix + "radio:manual:swr3"))
        #expect(!UserChoiceCatalog.isHarnessSeed(cloudKey: "radioNationalCountryCode"))
        // Every family is stripped, the hand-entered stations and the
        // variants too; a real station behind them stays real.
        for family in UserChoiceCatalog.familyPrefixes {
            #expect(UserChoiceCatalog.isHarnessSeed(cloudKey: family + "radio:manual:seed-1"), "\(family) lets a seed in")
            #expect(!UserChoiceCatalog.isHarnessSeed(cloudKey: family + "radio:manual:swr3"), "\(family) takes a real id for a seed")
        }
        // The family is stripped, so the anchor still stands at the id's
        // own start; and a real address behind a family stays real.
        #expect(!UserChoiceCatalog.isHarnessSeed(
            cloudKey: UserChoiceCatalog.subscriptionPrefix + "rss:9f8e:https://example.org/seed-book-club/ep1"))
        #expect(!UserChoiceCatalog.isHarnessSeed(
            cloudKey: UserChoiceCatalog.hiddenPrefix + "sub:album:my-seed-book"))
    }

    /// A new family prefix that the seed question does not strip lets seeds
    /// of that family in; the list is held to every prefix of the catalog.
    @Test("jedes Familien-Praefix des Katalogs steht in der Liste, die die Saat-Frage abzieht", .needsTheSources)
    func everyFamilyPrefixIsStripped() throws {
        let code = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/UserChoiceSync.swift"),
                              encoding: .utf8)
        let declared = code.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: #"static let [A-Za-z]+Prefix = ""#, options: .regularExpression) else { return nil }
            let rest = line[range.upperBound...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        #expect(declared.count >= 10, "the fence read the prefixes: \(declared)")
        let missing = declared.filter { !UserChoiceCatalog.familyPrefixes.contains($0) }
        #expect(missing.isEmpty, "family prefixes the seed question does not strip: \(missing)")
    }

    @Test("Ein geseedeter Sender reist nicht hinaus, ein echter schon") @MainActor
    func seedStationsDoNotTravel() {
        let suiteName = "harness-seed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let seed = RadioStation(id: "radio:manual:seed-2", name: "Seed Radio Two",
                                streamURL: "https://seed.example/stream")
        let real = RadioStation(id: "radio:manual:swr3", name: "SWR3",
                                streamURL: "https://swr3.example/stream")
        RadioStore.addManual(seed, defaults: defaults)
        RadioStore.addManual(real, defaults: defaults)
        #expect(RadioStore.manualStations(defaults: defaults).count == 2)
        // The one question the reconcile asks on both directions.
        let travelling = RadioStore.manualStations(defaults: defaults)
            .filter { !UserChoiceCatalog.isHarnessSeed(id: $0.id) }
        #expect(travelling.map(\.id) == ["radio:manual:swr3"])
    }

    @Test("Ein von Hand eingetragener Sender reist als eigene Aussage, das Entfernen als Grabstein") @MainActor
    func manualStationsTravelElementWise() {
        let suiteName = "manual-travel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cloud = InMemoryCloudStore()
        let sync = UserChoiceCloudSync(defaults: defaults, cloud: cloud, syncEnabled: { true },
                                       now: { 1_000 }, idFormSettled: { true })
        let station = RadioStation(id: "radio:manual:own-1", name: "Eigener Sender",
                                   streamURL: "https://own.example/stream")
        sync.noteManualStation(station, removed: false)
        let blob = cloud.dictionary(forKey: UserChoiceCloudSync.blobKey) ?? [:]
        let key = UserChoiceCatalog.manualStationPrefix + station.id
        #expect(blob[key] != nil, "the station travels as its own statement")
        // The removal is a tombstone under the same key, not a missing entry.
        sync.noteManualStation(station, removed: true)
        let after = cloud.dictionary(forKey: UserChoiceCloudSync.blobKey)?[key] as? [String: Any]
        #expect(after != nil && after?["v"] == nil, "a removal is a tombstone, not an absence")
    }
}
#endif
