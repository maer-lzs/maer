// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The canonical offline-unavailable predicate shared by every downloadable
/// media row (queue, browse deck, book/podcast rows).
struct MediaAvailabilityTests {
    @Test("offline + not downloaded → unavailable; any other combination → available")
    func offlineUnavailable() {
        #expect(MediaAvailability.offlineUnavailable(isConnected: false, isDownloaded: false))
        #expect(!MediaAvailability.offlineUnavailable(isConnected: false, isDownloaded: true))
        #expect(!MediaAvailability.offlineUnavailable(isConnected: true, isDownloaded: false))
        #expect(!MediaAvailability.offlineUnavailable(isConnected: true, isDownloaded: true))
    }

    /// The same fact the other way round. The display asks „dimmen?", the
    /// play gates ask „geht das jetzt?", and that MUST be the same answer:
    /// a row that dims as unplayable while a menu
    /// next to it offers playing is a contradiction on one screen.
    @Test("The positive form is exactly the negation in all four cases")
    func canPlayNowIsExactlyTheNegation() {
        for connected in [true, false] {
            for downloaded in [true, false] {
                #expect(MediaAvailability.canPlayNow(isConnected: connected, isDownloaded: downloaded)
                        == !MediaAvailability.offlineUnavailable(isConnected: connected,
                                                                 isDownloaded: downloaded),
                        "verbunden=\(connected) geladen=\(downloaded)")
            }
        }
        // And the one case that matters, written out.
        #expect(!MediaAvailability.canPlayNow(isConnected: false, isDownloaded: false))
    }

    /// The positive form had NO name for a long time, so nine callers spelled
    /// it out by hand, each a little differently: `!offline ||`,
    /// `online ||`, `isOnline ||`, `!isOffline ||`. They agreed, which
    /// was luck and no guarantee. This stock pins down that the
    /// two facts are no longer joined by hand.
    ///
    /// The three entries are NOT violations but other questions, and
    /// each names its own. Whoever adds a fourth must justify it.
    @Test("Nobody joins network and download by hand any more", .needsTheSources)
    func nobodyJoinsTheTwoFactsByHand() throws {
        let expected: [String: String] = [
            "Sources/ViewModels/PlayerViewModel.swift":
                "andere Frage: Selbstheilung. Geladen UND Spuren fehlen UND online ⇒ die "
                + "fehlenden nachholen. Das ist Reparatur, nicht Abspielbarkeit",
            "Sources/Views/Podcasts/PodcastComponents.swift":
                "andere Frage, zweimal: das Geladen-ABZEICHEN. Reine Anzeige einer Tatsache, "
                + "nicht die Verbindung zweier",
        ]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var found: Set<String> = []
        for url in SourceTree.files(under: root) where url.lastPathComponent.hasSuffix(".swift") {
            let text = try String(contentsOf: url, encoding: .utf8)
            // Comments gone (an explanation is not a call), then all
            // whitespace to one, so that a multi-line expression is
            // read as ONE text.
            let flat = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            for range in flat.ranges(of: "isDownloaded(itemId:") {
                // Whoever CALLS the rule joins nothing by hand. The question
                // must be asked LOCALLY:
                // „steht dieses Vorkommen als Argument `isDownloaded:` da?". My first version searched for
                // `MediaAvailability.` anywhere in the 260 characters before it,
                // so ONE real call further up in the same
                // file also covered every handwriting next to it, and the red probe
                // stayed green. An exclusion may only explain the finding
                // it touches, not its neighbourhood.
                let lookBack = flat.index(range.lowerBound, offsetBy: -60, limitedBy: flat.startIndex)
                    ?? flat.startIndex
                if flat[lookBack..<range.lowerBound].contains("isDownloaded:") { continue }
                let from = flat.index(range.lowerBound, offsetBy: -90, limitedBy: flat.startIndex) ?? flat.startIndex
                let to = flat.index(range.upperBound, offsetBy: 90, limitedBy: flat.endIndex) ?? flat.endIndex
                let window = String(flat[from..<to])
                if ["isConnected", "isOnline", "isOffline", "offline", "online"]
                    .contains(where: { window.contains($0) }) {
                    found.insert(SourceTree.relativePath(of: url))
                }
            }
        }
        let drift = found.symmetricDifference(Set(expected.keys)).sorted()
        #expect(found == Set(expected.keys),
                "neue oder verschwundene Stelle, die Netz und Download selbst verbindet: \(drift)")
    }
}
#endif
