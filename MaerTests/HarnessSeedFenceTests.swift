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

    @Test("Der Wahl-Schluessel traegt dieselbe Frage: die Familie davor aendert nichts")
    func theCloudKeyAsksTheSameQuestion() {
        #expect(UserChoiceCatalog.isHarnessSeed(cloudKey: UserChoiceCatalog.favoritePrefix + "radio:manual:seed-2"))
        #expect(UserChoiceCatalog.isHarnessSeed(cloudKey: UserChoiceCatalog.recentStationPrefix + "radio:rb:seed-pop-1"))
        #expect(!UserChoiceCatalog.isHarnessSeed(cloudKey: UserChoiceCatalog.favoritePrefix + "radio:manual:swr3"))
        #expect(!UserChoiceCatalog.isHarnessSeed(cloudKey: "radioNationalCountryCode"))
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
}
#endif
