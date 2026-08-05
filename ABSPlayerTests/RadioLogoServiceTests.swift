// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// 95c5c16: the negative cache poisoned itself — a transport failure was
/// written down as "this station has no logo" and held for 14 days, so ONE
/// disturbed phase (the RB outage on 03.08.) wiped every logo. These tests
/// fence the rule: only a clean run that found nothing may be booked.
struct RadioLogoCacheTests {
    private struct Stored: Codable {
        var url: String?
        var resolvedAt: Double
    }

    private func write(_ entries: [String: Stored], to defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(entries), forKey: "radioLogoChainResults")
    }

    private func read(_ defaults: UserDefaults) -> [String: Stored] {
        guard let data = defaults.data(forKey: "radioLogoChainResults") else { return [:] }
        return (try? JSONDecoder().decode([String: Stored].self, from: data)) ?? [:]
    }

    @Test("the poisoned negative generation is dropped once; positives survive")
    func selfHealing() {
        let suite = "radio-logo-heal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date().timeIntervalSince1970
        write(["radio:rb:good": Stored(url: "https://logo.example/a.png", resolvedAt: now),
               "radio:rb:poisoned": Stored(url: nil, resolvedAt: now)], to: defaults)

        // The migration the service performs on first load of this version.
        let dropped = RadioLogoService.migratePersisted(defaults: defaults,
                                                        storedVersion: 1)
        #expect(dropped == 1)
        let kept = read(defaults)
        #expect(kept["radio:rb:good"]?.url == "https://logo.example/a.png")
        #expect(kept["radio:rb:poisoned"] == nil)

        // Running it again at the current version changes nothing.
        #expect(RadioLogoService.migratePersisted(defaults: defaults,
                                                  storedVersion: RadioLogoService.currentStorageVersion) == 0)
        #expect(read(defaults).count == 1)
    }

    @Test("bc11ed5: the politeness spacing leaves room for a screen full of tiles")
    func politeSpacing() {
        // The old 1 s came from the MusicBrainz manners; this chain talks to
        // Wikidata/Commons. With a screenful of tiles the fourth station's
        // turn came minutes late — long after SwiftUI cancelled its task.
        #expect(RadioLogoService.politeSpacingSeconds < 0.5)
        #expect(RadioLogoService.politeSpacingSeconds > 0.2)   // still polite
        // A screen of ~12 tiles must drain in seconds, not minutes.
        #expect(12 * RadioLogoService.politeSpacingSeconds < 5)
    }

    @Test("a failed fetch is not a finding — only a clean no-hit may be booked")
    func failureIsNotANegative() {
        // The rule as a pure decision, so it holds independently of the network.
        #expect(!RadioLogoService.mayPersist(outcomeFailed: true, foundURL: nil))
        #expect(RadioLogoService.mayPersist(outcomeFailed: false, foundURL: nil))
        #expect(RadioLogoService.mayPersist(outcomeFailed: false,
                                            foundURL: URL(string: "https://logo.example/a.png")))
    }
}
#endif
