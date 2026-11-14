// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import SwiftUI
@testable import Maer

/// GOAL 3.0 point 3, first slice: „bin ich online" is a VALUE, no
/// reach into a guard. The seam comes with its fence: it pins down that
/// the value is set at exactly ONE place (a forgotten handover
/// would otherwise be silent, because the default value is „online"), and it
/// inventories the places that still ask the guard themselves; the
/// stock is the count, in both directions.
struct OnlineValueFenceTests {
    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// Non-comment lines of a file that name the access.
    static func reaches(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains("NetworkMonitor.shared")
            }.count
    }

    /// The stock per file, equal to the count; every entry carries
    /// its reason NEXT TO IT.
    ///
    /// The music context menu once stood here with the reason
    /// „Helfer ohne eigenes `self`" and wrongly so: its two accesses sat in a
    /// `ViewModifier` with its own `body`. Healed instead of re-justified. Exactly
    /// this case is why the reason now stands in the entry
    /// and not in a paragraph above it: there it could drift away from its
    /// entry without anyone noticing.
    nonisolated static let stock: [String: (count: Int, reason: String)] = [
        "RootView.swift":
            (1, "die EINE Stelle, die die Wache beobachtet und den Wert reicht"),
        "PodcastHelpers.swift":
            (2, "die Griffe sitzen in extension-View-Helfern ohne eigenes self; sie bekommen "
                + "den Wert in einer spaeteren Scheibe als Parameter vom Rufer"),
        "Lyrics.swift":
            (1, "ein Dienst, der nur unter Sources/Views wohnt, keine Ansicht"),
        "PodcastAutoContinue.swift":
            (1, "eine Regel, die nur unter Sources/Views wohnt, keine Ansicht"),
        "RadioArtwork.swift":
            (2, "fragt in zwei ASYNCHRONEN Seiteneffekten, ob das Netz stand, als ein Bild "
                + "nicht kam; das ist keine Zeichen-Frage, und ein Umgebungswert waere dort "
                + "der Stand vom Aufgabenbeginn"),
    ]

    @Test("The guard is asked in the views only within the stock", .needsTheSources)
    func viewsAskTheMonitorOnlyWhereTheStockSaysSo() throws {
        var counts: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            counts[file.lastPathComponent, default: 0] += Self.reaches(in: try String(contentsOf: file, encoding: .utf8))
        }
        // Per file both ways, so the total is the stock's total as well.
        let drift = StockDrift.findings(counts: counts, stock: Self.stock.mapValues(\.count))
        #expect(drift.isEmpty, "the monitor is back in a view, or a stock above the count: \(drift)")
        // Red probe in both directions: the checker sees the access…
        #expect(Self.reaches(in: "guard NetworkMonitor.shared.isConnected else { return }") == 1)
        // …and a comment about the access it does NOT see.
        #expect(Self.reaches(in: "// used to ask NetworkMonitor.shared") == 0)
    }

    @Test("The value is handed over at exactly ONE place", .needsTheSources)
    func exactlyOnePlaceHandsTheValueDown() throws {
        var setters: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let count = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !trimmed.hasPrefix("//") && trimmed.contains(".environment(\\.isOnline")
                }.count
            if count > 0 { setters.append("\(file.lastPathComponent): \(count)") }
        }
        // A second setter would be no error one can see: the default value
        // is „online", so a wrongly handed-over place would stay silent.
        #expect(setters == ["RootView.swift: 1"], "gesetzt wird an: \(setters)")
    }

    @Test("The guard publishes EXACTLY one answer, otherwise the root observer costs", .needsTheSources)
    func theMonitorPublishesExactlyOneAnswer() throws {
        // The condition on which the exception hangs. `@ObservedObject` hangs
        // on the OBJECT, not on the field: a second `@Published` on this guard
        // (connection kind, expensive network, a counter) would re-evaluate the root on every
        // change of it, that is the whole tree, although
        // the online answer stands still. That would be the stutter construction
        // at the worst possible place. Whoever wants to add a field here
        // must first take the observer out of the root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Networking/NetworkMonitor.swift"),
                              encoding: .utf8)
        let published = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains("@Published")
            }
        #expect(published.count == 1,
                """
                die Wache traegt \(published.count) veroeffentlichte Felder; \
                die Wurzel beobachtet sie und wuerde bei jeder Aenderung \
                jedes Feldes den ganzen Baum neu auswerten
                """)
        #expect(published.first?.contains("isConnected") == true)
    }

    @Test("The default value is ONLINE, because the gates only dim")
    func theDefaultIsOnline() {
        // A surface that never receives the value behaves as today,
        // instead of dimming everything. The opposite direction would be the worse one:
        // a library that shows itself as offline for no reason.
        #expect(EnvironmentValues().isOnline)
        // And the rule behind it stays the old, pure one: offline AND not
        // downloaded means not playable, everything else is available.
        #expect(MediaAvailability.offlineUnavailable(isConnected: false, isDownloaded: false))
        #expect(!MediaAvailability.offlineUnavailable(isConnected: false, isDownloaded: true))
        #expect(!MediaAvailability.offlineUnavailable(isConnected: true, isDownloaded: false))
    }
}
#endif
