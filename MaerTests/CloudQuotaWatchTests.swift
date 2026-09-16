// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The quota check must hold for the CHANNEL, not for one service.
@Suite struct CloudQuotaWatchTests {

    @Test func onlyTheQuotaReasonCounts() {
        #expect(CloudQuotaWatch.isQuotaViolation(NSUbiquitousKeyValueStoreQuotaViolationChange))
        #expect(!CloudQuotaWatch.isQuotaViolation(NSUbiquitousKeyValueStoreServerChange))
        #expect(!CloudQuotaWatch.isQuotaViolation(NSUbiquitousKeyValueStoreInitialSyncChange))
        #expect(!CloudQuotaWatch.isQuotaViolation(nil))
    }

    /// The app's start path runs more than once (tab switches, settings). The
    /// watch must not stack observers.
    @MainActor
    @Test func theWatchRegistersExactlyOnce() {
        let watch = CloudQuotaWatch(store: InMemoryCloudStore())
        watch.start()
        watch.start()
        watch.start()
        #expect(watch.observerRegistrations == 1)
    }

    /// The fence the order asks for, in the form that cannot drift: NOBODY
    /// observes the change notification without asking why it fired.
    ///
    /// A test would have watched one call site; this watches the CLASS. The
    /// defect it replaces was exactly of that shape. The check existed, in
    /// one of four places, and the one place bailed out when a switch was off.
    ///
    /// Read from the source path baked in at compile time; where the sources
    /// are not readable (a device run, a copied checkout) the case reports
    /// nothing rather than failing on its environment. Like the pbxproj fence.
    @Test(.needsTheSources) func everyObserverOfTheChangeNotificationAsksWhy() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources,
                                                          includingPropertiesForKeys: nil) else { return }
        var offenders: [String] = []
        var seen = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("didChangeExternallyNotification") else { continue }
            seen += 1
            // The watch itself IS the answer. It may name the constant.
            if url.lastPathComponent == "CloudQuotaWatch.swift" { continue }
            if !text.contains("CloudQuotaWatch") { offenders.append(url.lastPathComponent) }
        }
        #expect(seen > 0, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        #expect(offenders.isEmpty,
                "diese Beobachter prüfen den Grund nicht: \(offenders.joined(separator: ", "))")
    }

    /// And the counter-direction: nobody re-implements the comparison either.
    /// Two derivations of "the channel is full" would disagree on a screen.
    @Test func nobodyElseNamesTheQuotaConstant() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources,
                                                          includingPropertiesForKeys: nil) else { return }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard url.lastPathComponent != "CloudQuotaWatch.swift",
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("NSUbiquitousKeyValueStoreQuotaViolationChange") else { continue }
            offenders.append(url.lastPathComponent)
        }
        #expect(offenders.isEmpty,
                "die Regel steht doppelt: \(offenders.joined(separator: ", "))")
    }
}
#endif
