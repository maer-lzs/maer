// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Unsubscribing is ONE action: `podcastUnsubscribe(_:)`. It removes all
/// RSS copies of the same normalized address, ARCHIVES the ABS copies and
/// kicks off the gpodder reconcile.
///
/// Three user surfaces called `subs.unsubscribe(id:)` alone instead, which
/// knows only the RSS half. Whoever unsubscribed that way afterwards had a show
/// that stood in the tab WEITERSTAND (now as a server copy) and was gone
/// in the settings. That is the opposite direction of a reported show and the same
/// mechanism: two paths for one action, one of them incomplete.
///
/// The stock names its reason per caller. The two that may remain
/// are NOT user actions.
struct UnsubscribeDoorFenceTests {
    private func codeOf(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("Only the one action and two derived callers touch unsubscribing", .needsTheSources)
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
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let relative = SourceTree.relativePath(of: url)
            let count = try codeOf(relative)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.contains("unsubscribe(id:") && !$0.contains("func unsubscribe") }
                .count
            if count > 0 { found[relative] = count }
        }
        #expect(found == expected.mapValues(\.count),
                "eine Flaeche bestellt an der einen Handlung vorbei ab")
    }

    /// Counter-check: the one action really does both halves. Without this
    /// case the stock above could be right while `podcastUnsubscribe`
    /// itself has shrunk to the RSS half.
    @Test("The one action clears both sides", .needsTheSources)
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
