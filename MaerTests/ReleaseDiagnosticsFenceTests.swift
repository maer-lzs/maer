// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// No release build (TestFlight, App Store) reaches a diagnostics surface:
/// every way into one stands inside `#if DEBUG`, the code itself stays and
/// is reached from Xcode. The derived-store lever is no diagnostic and
/// stands in the storage section of every build.
struct ReleaseDiagnosticsFenceTests {

    /// The ways into a diagnostics surface, as their call reads, and why.
    static let entries: [(call: String, reason: String)] = [
        ("DiagnosticsView(", "the developer diagnostics page in the settings, with the books' progress diagnosis"),
        ("SyncHistoryView()", "the sync runs and counters"),
        ("diagnosisSection", "the progress diagnosis of a show's settings"),
        ("MetricReceiver.startIfAllowed()", "MetricKit, read only by the diagnostics page"),
        ("RadioLogoReport.text(", "the station logo and listening report of the radio tab"),
        ("BookmarkMeasure.Page()", "the bookmark measurement of linked folders"),
    ]

    /// The lines of `code` with the `#if` conditions around each, comment
    /// lines cut away. A line inside `#else` of a `#if DEBUG` counts as
    /// outside it.
    static func linesWithConditions(_ code: String) -> [(line: String, inDebug: Bool)] {
        var stack: [Bool] = []
        var out: [(String, Bool)] = []
        for raw in SyncContractFenceTests.stripped(code).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if") { stack.append(line == "#if DEBUG"); continue }
            if line.hasPrefix("#else") || line.hasPrefix("#elseif") { if !stack.isEmpty { stack[stack.count - 1] = false }; continue }
            if line.hasPrefix("#endif") { _ = stack.popLast(); continue }
            out.append((line, stack.contains(true)))
        }
        return out
    }

    /// Where a way into a diagnostics surface stands outside `#if DEBUG`.
    static func openEntries(in code: String, file: String) -> [String] {
        var open: [String] = []
        for (line, inDebug) in linesWithConditions(code) where !inDebug {
            for entry in entries {
                // A call, not the declaration: the section stands alone on
                // its line where it is placed.
                let hits = entry.call == "diagnosisSection" ? line == entry.call : line.contains(entry.call)
                if hits { open.append("\(file): \(line)") }
            }
        }
        return open
    }

    @Test("no way into a diagnostics surface outside #if DEBUG", .needsTheSources)
    func noDiagnosticsInARelease() throws {
        var open: [String] = []
        var reached = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for entry in Self.entries where text.contains(entry.call) { reached += 1 }
            // The diagnostics page lists its own sub pages; it is reached
            // only through its own entry, which stands in DEBUG.
            guard file.lastPathComponent != "DiagnosticsView.swift" else { continue }
            open += Self.openEntries(in: text, file: file.lastPathComponent)
        }
        #expect(reached >= Self.entries.count, "the fence found the entries it guards")
        #expect(open.isEmpty, "a release build reaches a diagnostics surface: \(open)")
        let settings = FetchAnswerTests.squeezed(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/SettingsView.swift"), encoding: .utf8))
        let storage = try #require(settings.range(of: "private var storageSection: some View {"))
        #expect(settings[storage.upperBound...].prefix(1_400).contains("ReloadCatalogDataRow()"),
                "the derived-store lever left the storage section")
        // The book progress diagnosis stands on the diagnostics page, not on
        // the book page.
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BookDetailScreen.swift"), encoding: .utf8))
        #expect(!page.contains("ProgressDiagnosis") && !page.contains("BookProgressReport"),
                "the book page carries the progress diagnosis again")
        let diagnostics = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/DiagnosticsView.swift"), encoding: .utf8))
        #expect(diagnostics.contains("BookProgressReport.text(for: entry)"))
    }

    @Test("the counter of the conditions: DEBUG counts, #else does not, a comment does not")
    func theConditionReader() {
        let code = """
        #if DEBUG
        diagnosisSection
        #else
        DiagnosticsView()
        #endif
        // SyncHistoryView()
        SyncHistoryView()
        private var diagnosisSection: some View {
        """
        #expect(Self.openEntries(in: code, file: "F") == ["F: DiagnosticsView()", "F: SyncHistoryView()"])
    }
}
#endif
