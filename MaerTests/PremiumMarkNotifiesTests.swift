// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Combine
@testable import Maer

/// The manual premium mark changed a value and left the
/// notifying to the CALLER. Four places did it, and all four remembered
/// to, which is luck and no guarantee. A fifth would have set the mark
/// and every row would have kept showing the old one, without a word.
///
/// The same form as `canPlayNow`: a duty that is spread over the callers
/// is a claim about all future callers.
@MainActor
struct PremiumMarkNotifiesTests {
    /// On BEHAVIOR: the change reports itself. The case holds the
    /// promise that was previously kept by hand in four places.
    @Test("The mark notifies by itself")
    func themarkNotifiesItself() async {
        let defaults = UserDefaults(suiteName: "premium-mark-test")!
        defaults.removePersistentDomain(forName: "premium-mark-test")
        var seen = 0
        let token = PodcastSubscriptions.shared.objectWillChange.sink { _ in seen += 1 }
        defer { token.cancel() }

        PodcastSubscriptions.setManualPremium(true, feedURL: "https://example.org/feed.xml",
                                              defaults: defaults)
        // The notification runs through a MainActor task, like the cloud
        // note beside it; one pass suffices to let it arrive.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(seen > 0, "die Markierung aendert etwas, ohne dass eine Flaeche davon erfaehrt")

        // And the thing itself really happened, otherwise the case would check
        // only a publisher.
        #expect(PodcastSubscriptions.isManuallyMarkedPremium("https://example.org/feed.xml",
                                                             defaults: defaults))
        defaults.removePersistentDomain(forName: "premium-mark-test")
    }

    /// And the count: no caller still triggers the publisher itself. Whoever
    /// does it again has spread the duty back over the callers.
    @Test("No surface triggers the subscription publisher itself after a mark", .needsTheSources)
    func noSurfacePokesThePublisher() throws {
        let allowed: [String: String] = [
            "Sources/Providers/PodcastSubscriptions.swift":
                "die Ablage selbst: dort steht die Aenderung und dort steht die Meldung",
            "Sources/Views/Podcasts/PodcastPlayState.swift":
                "ein anderer Speicher mit eigenem Publisher, nicht der Abo-Speicher",
        ]
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let relative = SourceTree.relativePath(of: url)
            if allowed[relative] != nil { continue }
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("subs.objectWillChange.send()")
                || code.contains("PodcastSubscriptions.shared.objectWillChange.send()") {
                offenders.append(relative)
            }
        }
        #expect(offenders.isEmpty,
                "eine Flaeche meldet die Aenderung wieder selbst: \(offenders)")
    }
}
#endif
