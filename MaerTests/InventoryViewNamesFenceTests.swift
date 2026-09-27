// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every view that is not private is NAMED in the inventory: in the first or
/// second cell of a row, where a reader looks for a component and its users.
/// A name that stands only deeper in a row's prose cannot be found as a
/// component; measured 27.09.2026 at seven views, three of them found one by
/// one from outside, and two views were in no row at all.
struct InventoryViewNamesFenceTests {
    /// The identifiers in the first two cells of every table row. Cells split
    /// at unescaped pipes, as the renderer splits them.
    nonisolated static func namedInInventory(_ text: String) -> Set<String> {
        var names: Set<String> = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|"), !trimmed.allSatisfy({ "|-: ".contains($0) }) else { continue }
            var cells: [String] = [""]
            var previous: Character = " "
            for ch in trimmed {
                if ch == "|" && previous != "\\" { cells.append("") } else { cells[cells.count - 1].append(ch) }
                previous = ch
            }
            // cells[0] is what stands before the first pipe.
            for cell in cells.dropFirst().prefix(2) {
                for token in cell.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }) {
                    names.insert(String(token))
                }
            }
        }
        return names
    }

    /// The views a source declares that are not private, by name.
    nonisolated static func declaredViews(in source: String) -> [String] {
        let declaration = #/^\s*(?:@\w+\s+)*(?:(public|internal|private|fileprivate)\s+)?struct\s+(\w+)(?:<[^>]*>)?\s*:([^{]*)/#
        var out: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = line.firstMatch(of: declaration) else { continue }
            if let access = match.output.1, access == "private" || access == "fileprivate" { continue }
            let conformances = match.output.3.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            if conformances.contains("View") { out.append(String(match.output.2)) }
        }
        return out
    }

    @Test("Jede nicht-private View steht im Inventar in Spalte 1 oder 2", .needsTheSources)
    func everyViewIsNamed() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let inventory = try String(contentsOf: root.appendingPathComponent("docs/components.md"), encoding: .utf8)
        let named = Self.namedInInventory(inventory)
        var views: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            views += Self.declaredViews(in: try String(contentsOf: file, encoding: .utf8))
        }
        #expect(views.contains("AppSwitch") && views.count > 100, "the finder sees the views: \(views.count)")
        let unnamed = views.filter { !named.contains($0) }.sorted()
        #expect(unnamed.isEmpty, "views no row names in its first two cells: \(unnamed)")

        // The checker: first and second cell count, the third does not; an
        // escaped pipe does not split; private views are not asked.
        let table = "| A | B | C |\n|---|---|---|\n| `One` + `Two` | used by `Three` | also `Four` |\n| `x \\| Five` | y | z |\n"
        #expect(Self.namedInInventory(table).isSuperset(of: ["One", "Two", "Three", "Five"]))
        #expect(!Self.namedInInventory(table).contains("Four"), "the third cell names nothing")
        let source = """
        struct Shown: View {
        private struct Hidden: View {
        fileprivate struct AlsoHidden: View {
        struct Generic<Label: View>: View {
        @MainActor struct Marked: View, Equatable {
        struct NotAView: ViewModifier {
        struct Model: Equatable {
        """
        #expect(Self.declaredViews(in: source) == ["Shown", "Generic", "Marked"])
    }
}
#endif
