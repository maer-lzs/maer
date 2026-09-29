// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Abbestellen ist EINE Handlung: `podcastUnsubscribe(_:)`. Sie entfernt alle
/// RSS-Kopien derselben normalisierten Adresse, ARCHIVIERT die ABS-Kopien und
/// stösst den gpodder-Abgleich an.
///
/// Drei Nutzer-Flächen riefen stattdessen `subs.unsubscribe(id:)` allein, das
/// nur die RSS-Hälfte kennt. Wer so abbestellte, hatte danach eine Sendung,
/// die im Tab WEITERSTAND (jetzt als Server-Kopie) und in den Einstellungen
/// weg war. Das ist die Gegenrichtung einer gemeldeten Sendung und derselbe
/// Mechanismus: zwei Wege für eine Handlung, einer unvollständig.
///
/// Der Bestand nennt je Rufer seinen Grund. Die zwei, die bleiben dürfen,
/// sind KEINE Nutzer-Handlungen.
struct UnsubscribeDoorFenceTests {
    private func codeOf(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("Nur die eine Handlung und zwei abgeleitete Rufer fassen das Abbestellen an")
    func onlyTheOneActionUnsubscribes() throws {
        let expected: [String: (count: Int, reason: String)] = [
            "Sources/Views/Podcasts/PodcastHelpers.swift":
                (1, "die EINE Handlung selbst (podcastUnsubscribe): RSS-Kopien weg, ABS-Kopien "
                    + "archiviert, gpodder abgeglichen"),
            "Sources/Networking/GPodderSync.swift":
                (2, "ABGELEITETE Entfernung: der Server hat abbestellt, nicht die Person. "
                    + "Beide mit notesCloud: false, und eine ABS-Kopie zu archivieren waere hier "
                    + "falsch, weil gpodder nur die RSS-Seite kennt"),
            "Sources/Providers/PodcastSubscriptions.swift":
                (3, "die Ablage selbst: das freie Abo weicht dem Premium-Feed derselben Sendung, "
                    + "die abgelehnte Adresse weicht ihrem neuen Link, und der abgelehnte "
                    + "Bezahl-Feed weicht seinem freien Zwilling; alle drei kein Abbestellen, "
                    + "sondern ein Austausch"),
        ]
        var found: [String: Int] = [:]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        for case let name as String in walker where name.hasSuffix(".swift") {
            let count = try codeOf("Sources/" + name)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.contains("unsubscribe(id:") && !$0.contains("func unsubscribe") }
                .count
            if count > 0 { found["Sources/" + name] = count }
        }
        #expect(found == expected.mapValues(\.count),
                "eine Flaeche bestellt an der einen Handlung vorbei ab")
    }

    /// Gegenprobe: die eine Handlung tut wirklich beide Hälften. Ohne diesen
    /// Fall könnte der Bestand oben stimmen, während `podcastUnsubscribe`
    /// selbst auf die RSS-Hälfte zusammengeschrumpft ist.
    @Test("Die eine Handlung raeumt beide Seiten")
    func theOneActionClearsBothSides() throws {
        let code = try codeOf("Sources/Views/Podcasts/PodcastHelpers.swift")
        guard let action = code.range(of: "func podcastUnsubscribe") else {
            Issue.record("die Handlung wurde umbenannt"); return
        }
        let to = code.index(action.lowerBound, offsetBy: 700, limitedBy: code.endIndex) ?? code.endIndex
        let body = String(code[action.lowerBound..<to])
        #expect(body.contains("normalizeFeedURL"),
                "die Handlung vergleicht nicht mehr ueber die normalisierte Adresse")
        #expect(body.contains("PodcastSubscriptions.shared.unsubscribe(id:"),
                "die RSS-Haelfte fehlt")
        #expect(body.contains("setArchived"),
                "die ABS-Haelfte fehlt: die Server-Kopie bliebe im Tab stehen")
        #expect(body.contains("GPodderSync.shared.reconcile"),
                "der gpodder-Abgleich fehlt")
    }
}
#endif
