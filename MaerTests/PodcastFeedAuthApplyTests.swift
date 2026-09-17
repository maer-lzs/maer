// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A moment is booked only for a write that landed, and an apply that does
/// not know its own stock does nothing. Before this, a locked keychain
/// listed as nil became "empty", every arriving entry was written (failing
/// silently) and stamped with the newer moment, and the old secret won every
/// merge from then on. The keychain write is handed in so it can fail here.
struct PodcastFeedAuthApplyTests {
    private func suite() -> (UserDefaults, String) {
        let name = "feed-auth-apply-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func stamps(_ defaults: UserDefaults) -> [String: Double] {
        (defaults.dictionary(forKey: PodcastFeedAuth.stampsKey) as? [String: Double]) ?? [:]
    }

    private let entry = FeedAuthBlock.Entry(credentials: .init(user: "u", password: "p"), at: 1_700_000_000_000)

    @Test("ein apply ohne eigenen Bestand tut nichts: kein Schrieb, kein Stempel")
    func applyWithoutOwnStockDoesNothing() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var writes = 0
        PodcastFeedAuth.apply(["feed-a": entry], mine: nil, defaults: defaults,
                              writing: { _, _, _ in writes += 1; return true })
        #expect(writes == 0, "nothing may be written when the keychain could not be listed")
        #expect(stamps(defaults).isEmpty, "nothing may be stamped either")
    }

    @Test("gestempelt wird nur ein gelungener Schrieb; ein gescheiterter laesst den Moment stehen")
    func onlyALandedWriteIsStamped() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["feed-a": 1_600_000_000_000.0], forKey: PodcastFeedAuth.stampsKey)
        PodcastFeedAuth.apply(["feed-a": entry], mine: [:], defaults: defaults,
                              writing: { _, _, _ in false })
        #expect(stamps(defaults)["feed-a"] == 1_600_000_000_000, "a failed write keeps the old moment")
        PodcastFeedAuth.apply(["feed-a": entry], mine: [:], defaults: defaults,
                              writing: { _, _, _ in true })
        #expect(stamps(defaults)["feed-a"] == 1_700_000_000_000, "a landed write books the entry's moment")
        // What already matches is left alone, and not re-stamped.
        var writes = 0
        PodcastFeedAuth.apply(["feed-a": entry], mine: ["feed-a": entry], defaults: defaults,
                              writing: { _, _, _ in writes += 1; return true })
        #expect(writes == 0)
    }

    @Test("die eigene Eingabe: ohne gelandeten Schrieb kein neuer Moment")
    func ownEditStampsOnlyALandedWrite() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["feed-b": 1_600_000_000_000.0], forKey: PodcastFeedAuth.stampsKey)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        PodcastFeedAuth.set(feedKey: "feed-b", user: "u", password: "p", now: now, defaults: defaults,
                            writing: { _, _, _ in false })
        #expect(stamps(defaults)["feed-b"] == 1_600_000_000_000, "the moment stays when the write failed")
        PodcastFeedAuth.set(feedKey: "feed-b", user: "u", password: "p", now: now, defaults: defaults,
                            writing: { _, _, _ in true })
        #expect(stamps(defaults)["feed-b"] == 1_700_000_000_000)
    }
}
#endif
