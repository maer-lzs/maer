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

    /// Dieselbe Tatsache andersherum. Die Anzeige fragt „dimmen?", die
    /// Spiel-Tore fragen „geht das jetzt?", und das MUSS dieselbe Antwort
    /// sein: eine Zeile, die als unspielbar dimmt, waehrend ein Menue
    /// daneben Abspielen anbietet, ist ein Widerspruch auf einem Bildschirm.
    @Test("Die positive Fassung ist in allen vier Faellen genau die Verneinung")
    func canPlayNowIsExactlyTheNegation() {
        for connected in [true, false] {
            for downloaded in [true, false] {
                #expect(MediaAvailability.canPlayNow(isConnected: connected, isDownloaded: downloaded)
                        == !MediaAvailability.offlineUnavailable(isConnected: connected,
                                                                 isDownloaded: downloaded),
                        "verbunden=\(connected) geladen=\(downloaded)")
            }
        }
        // Und der eine Fall, auf den es ankommt, ausgeschrieben.
        #expect(!MediaAvailability.canPlayNow(isConnected: false, isDownloaded: false))
    }

    /// Die positive Fassung hatte lange KEINEN Namen, also buchstabierten
    /// neun Rufer sie von Hand, jeder etwas anders: `!offline ||`,
    /// `online ||`, `isOnline ||`, `!isOffline ||`. Sie waren sich einig, was
    /// Glueck war und keine Zusicherung. Dieser Bestand haelt fest, dass die
    /// zwei Tatsachen nicht mehr von Hand verbunden werden.
    ///
    /// Die drei Eintraege sind KEINE Verstoesse, sondern andere Fragen, und
    /// jeder nennt seine. Wer einen vierten anlegt, muss ihn begruenden.
    @Test("Niemand verbindet Netz und Download mehr von Hand")
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
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        var found: Set<String> = []
        for case let name as String in walker where name.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            // Kommentare weg (eine Erklaerung ist kein Aufruf), dann alle
            // Zwischenraeume zu einem, damit ein mehrzeiliger Ausdruck als
            // EIN Text gelesen wird.
            let flat = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            for range in flat.ranges(of: "isDownloaded(itemId:") {
                // Wer die Regel RUFT, verbindet nichts von Hand. Die Frage
                // muss LOKAL gestellt werden: „steht dieses Vorkommen als
                // Argument `isDownloaded:` da?". Meine erste Fassung suchte
                // `MediaAvailability.` irgendwo in den 260 Zeichen davor —
                // damit deckte EIN echter Aufruf weiter oben in derselben
                // Datei jede Handschrift daneben mit ab, und die Rot-Probe
                // blieb gruen. Ein Ausschluss darf nur den Fund erklaeren,
                // den er anfasst, nicht seine Nachbarschaft.
                let lookBack = flat.index(range.lowerBound, offsetBy: -60, limitedBy: flat.startIndex)
                    ?? flat.startIndex
                if flat[lookBack..<range.lowerBound].contains("isDownloaded:") { continue }
                let from = flat.index(range.lowerBound, offsetBy: -90, limitedBy: flat.startIndex) ?? flat.startIndex
                let to = flat.index(range.upperBound, offsetBy: 90, limitedBy: flat.endIndex) ?? flat.endIndex
                let window = String(flat[from..<to])
                if ["isConnected", "isOnline", "isOffline", "offline", "online"]
                    .contains(where: { window.contains($0) }) {
                    found.insert("Sources/" + name)
                }
            }
        }
        let drift = found.symmetricDifference(Set(expected.keys)).sorted()
        #expect(found == Set(expected.keys),
                "neue oder verschwundene Stelle, die Netz und Download selbst verbindet: \(drift)")
    }
}
#endif
