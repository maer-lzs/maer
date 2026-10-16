// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A measurement for the open question E4 (moving the mirrors out of the
/// defaults into the database), not a change: the size of one mirror blob
/// at 22,000 stands, and how long one write of it into a defaults domain
/// takes. Every write of a mirror writes the whole blob. The numbers stand
/// in the test log (`STANDBLOB`); the case holds only that the measure ran.
@Suite(.serialized)
struct StandBlobMeasureTests {
    @Test("Messung E4: ein Spiegel mit 22.000 Staenden, Groesse und Schreibdauer in den Voreinstellungen")
    func theMirrorBlobAt22000Stands() {
        let suite = "standblob-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var mirror: [String: [Double]] = [:]
        for index in 0..<22_000 {
            mirror["rss:feed-\(index / 40):episode-\(UUID().uuidString)"] = [Double(index % 3600), 1_760_000_000_000 + Double(index), 3600]
        }
        var durations: [Double] = []
        for round in 0..<5 {
            mirror["rss:feed-0:round"] = [Double(round), 1_760_000_000_000, 3600]
            let started = Date()
            StandMirrorStore.save(mirror, key: "cloudStandMirror", defaults: defaults)
            durations.append(Date().timeIntervalSince(started) * 1000)
        }
        let bytes = defaults.data(forKey: "cloudStandMirror")?.count ?? 0
        let started = Date()
        let read = StandMirrorStore.load("cloudStandMirror", defaults: defaults)
        let readMs = Date().timeIntervalSince(started) * 1000
        let sorted = durations.sorted()
        print(String(format: "STANDBLOB stands=%d bytes=%d write_ms_median=%.1f write_ms_max=%.1f read_ms=%.1f",
                     read.count, bytes, sorted[sorted.count / 2], sorted.last ?? 0, readMs))
        #expect(read.count == 22_001, "the precondition: the measure wrote and read the whole mirror")
        #expect(bytes > 0)
    }
}
#endif
