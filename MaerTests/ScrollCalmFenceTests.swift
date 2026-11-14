// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// GOAL 3.0 point 3, calm gate: „fuehre das aus, wenn das Scrollen ruht" is
/// ONE question with ONE name. Before, TWENTY-TWO callers asked the
/// bottom bar directly, among them FOURTEEN stores and view models.
/// (The first version of this header said seventeen and nine. Those were the
/// numbers from a count that only looked at `Sources/Views`; the case
/// below refuted them in the same commit, the sentence did not.)
///
/// The fence holds two things, and the second is the more important:
///
/// 1. Nobody except the door calls the bar's queue itself.
/// 2. **Way B as a remainder WITH A NUMBER, not as a statement of intent.** A
///    store that schedules UI work is the actual
///    layer violation; renaming the gate only named it better.
///    The deeper cut turns it around: the store hands its fresh
///    value OUT, the view decides when to apply it. It
///    belongs to the tab cut, where these view models are opened
///    anyway. **It is done when this stock is zero.**
struct ScrollCalmFenceTests {
    static func calls(of token: String, in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains(token)
            }.count
    }

    /// Who still calls the bar's queue itself. Only the door.
    nonisolated static let queueStock: [String: (count: Int, reason: String)] = [
        "ScrollCalm.swift": (1, "IST die Tuer; der eine Griff, der die einundzwanzig anderen ersetzt hat"),
        "BottomBarState.swift": (1, "die Leiste selbst, die die Warteschlange haelt und leert"),
    ]

    /// **Way B, the named remainder with a number.** Types that are NOT views
    /// and still schedule UI work. It is the count; an empty
    /// stock means no such type schedules any more.
    ///
    /// Counting happens at the enclosing TYPE, not at the file: a file
    /// often holds a store AND its views, and a count per
    /// file would have hidden half the remainder (`FreeCatalogRows.swift`
    /// had both, until the store moved into a file of its own).
    nonisolated static let schedulingStoresStock: [String: (count: Int, reason: String)] = [
        "MusicViewModel":
            (6, "Alben, Neuestes, Zuletzt, Haeufig, Kuenstler und Playlisten kommen nach; das "
                + "Ansichtsmodell plant heute selbst ein, statt den Wert herauszugeben"),
        "FreeCatalogStore":
            (3, "der Katalog-Speicher setzt seine geladenen Reihen selbst, aus demselben Grund"),
        "LateMusicValues":
            (1, "die nachlaufenden Musikwerte setzen sich selbst, sobald sie eintreffen, durch eine Tuer"),
        "OERRLiveStore":
            (1, "der Hoerspiel-Speicher setzt seine Eintraege selbst"),
        "LibraryViewModel":
            (1, "das Bibliotheks-Modell wendet seine berechnete Ausgabe selbst an"),
    ]

    @Test("The bar's queue is called only by the door", .needsTheSources)
    func onlyTheDoorAsksTheQueue() throws {
        var counts: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            counts[file.lastPathComponent, default: 0] += Self.calls(of: "runWhenCalm", in: try String(contentsOf: file, encoding: .utf8))
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.queueStock.mapValues(\.count))
        #expect(drift.isEmpty, "a caller asks the bar itself again, or a stock above the count: \(drift)")
        // Red probe in both directions.
        #expect(Self.calls(of: "runWhenCalm", in: "BottomBarState.shared.runWhenCalm { x() }") == 1)
        #expect(Self.calls(of: "runWhenCalm", in: "// war BottomBarState.shared.runWhenCalm") == 0)
    }

    /// How often a type that is NOT a view schedules UI work. The
    /// enclosing type is the nearest declaration above the line.
    static func schedulingNonViews(in text: String) -> [String: Int] {
        var out: [String: Int] = [:]
        var enclosing = ""
        var isView = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // ONLY top-level declarations. A nested type
            // (an enumeration in a view) would otherwise be the
            // supposed host of every call below it, and the fence
            // would report names that do not exist as callers at all.
            if !trimmed.hasPrefix("//"), line.first != " ", line.first != "\t",
               let name = Self.declaredType(in: trimmed) {
                enclosing = name
                isView = trimmed.contains(": View") || trimmed.contains(": ViewModifier")
            }
            guard !trimmed.hasPrefix("//"), trimmed.contains("ScrollCalm.run"), !isView,
                  !enclosing.isEmpty else { continue }
            out[enclosing, default: 0] += 1
        }
        return out
    }

    static func declaredType(in line: String) -> String? {
        for keyword in ["final class ", "class ", "struct ", "enum ", "actor "]
        where line.contains(keyword) {
            guard let after = line.range(of: keyword) else { continue }
            let rest = line[after.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { return String(name) }
        }
        return nil
    }

    @Test("Types that are not views and schedule UI work only get fewer", .needsTheSources)
    func storesThatScheduleUIWorkOnlyShrink() throws {
        var counts: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            for (type, count) in Self.schedulingNonViews(in: try String(contentsOf: file, encoding: .utf8)) {
                counts[type, default: 0] += count
            }
        }
        // Measured, not claimed: per type both ways, so the rest is the
        // stock's total as well.
        let drift = StockDrift.findings(counts: counts, stock: Self.schedulingStoresStock.mapValues(\.count))
        #expect(drift.isEmpty, "a new store schedules UI work, or a stock above the count: \(drift)")
        // Red probe: a view may schedule, that is its job; a
        // store next to it may not.
        let mixed = """
            struct EinBild: View {
                func f() { ScrollCalm.run { x() } }
            }
            final class EinSpeicher: ObservableObject {
                func g() { ScrollCalm.run { y() } }
            }
            """
        #expect(Self.schedulingNonViews(in: mixed) == ["EinSpeicher": 1])
    }
}
#endif
