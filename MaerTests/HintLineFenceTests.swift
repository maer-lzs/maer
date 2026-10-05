// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// The fence that keeps the orange hint line one building block
/// (`HintLine`). Copies by hand drifted in size and colour; the fence counts
/// the orange sites of the views per file, each with the reason it is not
/// a hint line of a section, in both directions: a new site has to be a
/// `HintLine` or name its reason here, and a site that left takes its entry.
@Suite struct HintLineFenceTests {
    /// The orange sites of `Sources/Views`, per file, with the reason.
    nonisolated static let orangeStock: [String: (count: Int, reason: String)] = [
        "HintLine.swift": (1, "the building block itself"),
        "RowsSettingsView.swift": (2, "notes of a row, text without a symbol, beside the row's other notes"),
        "CatalogDetailExtras.swift": (1, "the import result in its row, beside the green and grey results"),
        "SyncHistoryView.swift": (1, "the guard note of a history entry, in the entry's caption rhythm"),
        "ShowAccessRefusedBanner.swift": (1, "the symbol of a banner title, not a sentence"),
        "PremiumBadge.swift": (1, "a badge, no sentence"),
    ]

    nonisolated static func orangeSites(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains(".orange)")
            }.count
    }

    @Test("jede orange Stelle der Ansichten ist die Hinweis-Zeile oder steht mit Grund im Bestand", .needsTheSources)
    func everyOrangeSiteIsTheHintLineOrNamed() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")
        let walker = try #require(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        var found: [String: Int] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let count = Self.orangeSites(in: try String(contentsOf: url, encoding: .utf8))
            if count > 0 { found[url.lastPathComponent, default: 0] += count }
        }
        #expect(found["HintLine.swift"] == 1, "the fence read the views")
        #expect(found == Self.orangeStock.mapValues(\.count),
                "an orange site by hand, or one that left its entry: \(found.sorted { $0.key < $1.key })")
        // Calibration: a site counts, a comment that names it does not.
        #expect(Self.orangeSites(in: "Label(x).foregroundStyle(.orange)\n// .foregroundStyle(.orange) here") == 1)
    }
}
#endif
