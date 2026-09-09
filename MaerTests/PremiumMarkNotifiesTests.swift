// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Combine
@testable import Maer

/// Die manuelle Premium-Markierung aenderte einen Wert und ueberliess das
/// Benachrichtigen dem RUFER. Vier Stellen taten es, und alle vier dachten
/// daran — was Glueck ist und keine Zusage. Eine fuenfte haette die Markierung
/// gesetzt und jede Zeile haette die alte weitergezeigt, ohne ein Wort.
///
/// Dieselbe Form wie `canPlayNow`: eine Pflicht, die auf die Rufer verteilt
/// ist, ist eine Behauptung ueber alle kuenftigen Rufer.
@MainActor
struct PremiumMarkNotifiesTests {
    /// Am VERHALTEN: die Aenderung selbst meldet sich. Der Fall haelt das
    /// Versprechen, das vorher an vier Stellen von Hand eingeloest wurde.
    @Test("Die Markierung benachrichtigt selbst")
    func themarkNotifiesItself() async {
        let defaults = UserDefaults(suiteName: "premium-mark-test")!
        defaults.removePersistentDomain(forName: "premium-mark-test")
        var seen = 0
        let token = PodcastSubscriptions.shared.objectWillChange.sink { _ in seen += 1 }
        defer { token.cancel() }

        PodcastSubscriptions.setManualPremium(true, feedURL: "https://example.org/feed.xml",
                                              defaults: defaults)
        // Die Meldung laeuft ueber eine MainActor-Aufgabe, wie die Wolken-
        // Notiz daneben; ein Durchlauf genuegt, um sie ankommen zu lassen.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(seen > 0, "die Markierung aendert etwas, ohne dass eine Flaeche davon erfaehrt")

        // Und die Sache selbst ist wirklich passiert, sonst pruefte der Fall
        // nur einen Publisher.
        #expect(PodcastSubscriptions.isManuallyMarkedPremium("https://example.org/feed.xml",
                                                             defaults: defaults))
        defaults.removePersistentDomain(forName: "premium-mark-test")
    }

    /// Und der Bestand: kein Rufer stoesst den Publisher noch selbst an. Wer
    /// es wieder tut, hat die Pflicht zurueck auf die Rufer verteilt.
    @Test("Keine Flaeche stoesst den Abo-Publisher nach einer Markierung selbst an")
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
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        for case let name as String in walker where name.hasSuffix(".swift") {
            let relative = "Sources/" + name
            if allowed[relative] != nil { continue }
            let code = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
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
