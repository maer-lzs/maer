// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A fence with a reasoned stock is better than one without, but every
/// reason in it is a STATEMENT ABOUT THE CODE, and it can age
/// or be off from the start. Documented cases: a sentence claimed
/// „kein neuer Beobachter" where one arose; a reason named
/// a helper without its own `self` where a `ViewModifier` with its own
/// `body` stood. Each time the BUILD was right and the sentence beside it
/// wrong, and none of these errors ever turns red.
///
/// The first attempt against it was a fence that holds the reason paragraph and
/// the stock against each other. It showed two things, both against
/// itself: it forced a TRUE sentence to be reworded (a note
/// that a file once wrongly stood in the stock disturbed it), and
/// it kept an opt-in list, that is a fix at the place of discovery for exactly the
/// class whose lesson is „die Klasse suchen, nicht den Fundort fixen".
///
/// Both go away when the reason cannot stand beside the entry at all,
/// but INSIDE it: `[String: (count: Int, reason: String)]`.
/// Then no reason can drift away from its entry, none can invent a file
/// and none can leave one out, and running text beside it is free again.
/// The shape already existed in the repo (`AblageFenceTests`,
/// `PublicLogAddressFenceTests`); the two young fences had invented a
/// second one and were moved to the existing one.
///
/// This fence now holds only the SHAPE, and it SEARCHES for its candidates:
/// every test file with a file stock keeps its reasons in the entry
/// or says expressly that it keeps none.
///
/// Individual reasons pay off where the entries DIFFER. Where
/// one sentence covers the whole stock, it belongs above it and the marker
/// says so: at the concurrency seam the reason stands AT THE PLACE OF DISCOVERY
/// anyway and is enforced there, a copy here would be a second place that can
/// drift. The marker is no excuse, it is the visible
/// choice; without it nobody has merely never noticed.
struct StockReasonFenceTests {
    static let marker = "BESTAND OHNE EINZELGRUENDE:"

    /// A file stock is a `static let` collection that maps file names to
    /// a NUMBER, that is to an allowed amount. Three kinds drop
    /// out with that, and that is intended:
    ///
    /// - a fence that merely READS two source files has no collection
    /// - `[String: String]` maps to a reason, so it is itself already
    ///   the reasoned shape
    /// - `[String: Set<String>]` is a data mapping, no stock
    static func fileStocks(in text: String) -> [(declaration: String, names: Set<String>, excused: Bool)] {
        var out: [(String, Set<String>, Bool)] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let head = lines[index].trimmingCharacters(in: .whitespaces)
            guard !head.hasPrefix("//"), head.contains("static let"),
                  head.contains("[String"), head.contains("Int") else { index += 1; continue }
            // The marker belongs to the STOCK, not to the file: a
            // file can keep several, and one marker for all would
            // silently exempt a future one that could be reasoned. So it stands
            // in the comment block directly above.
            var excused = false
            var above = index - 1
            while above >= 0 {
                let line = lines[above].trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("//") || line.isEmpty else { break }
                if line.contains(Self.marker) { excused = true; break }
                above -= 1
            }
            var names: Set<String> = []
            var cursor = index
            while cursor < lines.count {
                let body = lines[cursor].trimmingCharacters(in: .whitespaces)
                for token in body.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "+") })
                where token.hasSuffix(".swift") {
                    names.insert(String(token))
                }
                // The declaration ends where its bracket closes; if it lies
                // wholly in one line, it ends with that line. Without
                // that the searcher read into the next declaration and
                // credited an empty stock with foreign names.
                if body.hasSuffix("]") || (cursor > index && body.hasPrefix("]")) { break }
                cursor += 1
            }
            if names.count >= 2 { out.append((head, names, excused)) }
            index = cursor + 1
        }
        return out
    }

    @Test("Every file stock keeps its reasons in the entry, or says that it has none", .needsTheTests)
    func everyFileStockCarriesItsReasons() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var offenders: [String] = []
        var candidates = 0
        // The own file stays out, and with a reason: its
        // stocks are test data in strings, no stocks. The
        // searcher cannot tell the difference, and teaching it that
        // would mean aligning it to a special case. The assertion on
        // the candidate count below catches it, should the exception ever hide
        // more than it should.
        let own = URL(fileURLWithPath: #filePath).lastPathComponent
        for file in files where file.lastPathComponent != own {
            let text = try String(contentsOf: file, encoding: .utf8)
            let stocks = Self.fileStocks(in: text)
            guard !stocks.isEmpty else { continue }
            candidates += stocks.count
            for stock in stocks where !stock.excused && !stock.declaration.contains("reason:") {
                offenders.append("\(file.lastPathComponent): \(stock.names.count) Dateien ohne Grund im Eintrag")
            }
        }
        // Without this assertion a searcher that finds nothing any more would be
        // a green fence without a measurement.
        #expect(candidates >= 7, "der Kandidaten-Sucher findet fast nichts: \(candidates)")
        #expect(offenders.isEmpty,
                """
                \(offenders). Ein Datei-Bestand traegt seinen Grund im Eintrag \
                ([String: (count: Int, reason: String)]), damit er nicht von ihm \
                abdriften kann. Wer keine Gruende fuehren will, schreibt \
                „\(Self.marker) <warum nicht>" in die Datei
                """)
    }

    @Test("The searcher finds stocks and no read paths")
    func theSearcherFindsStocksNotPaths() {
        let stock = """
            struct A {
                nonisolated static let stock: [String: Int] = [
                    "Foo.swift": 1,
                    "Bar.swift": 2,
                ]
            }
            """
        #expect(Self.fileStocks(in: stock).first?.names == ["Foo.swift", "Bar.swift"])
        // Red probe in the other direction: two READ paths are no
        // stock, and a fence that only greps should not be put under the duty.
        let paths = """
            func check() throws {
                let a = try source("Sources/Views/Foo.swift")
                let b = try source("Sources/Views/Bar.swift")
            }
            """
        #expect(Self.fileStocks(in: paths).isEmpty)
        // And a single name is not yet a collection.
        let single = "    static let home: [String: Int] = [\"Foo.swift\": 1]"
        #expect(Self.fileStocks(in: single).isEmpty)
    }

    @Test("The marker exempts the STOCK, not the file")
    func theExcuseBindsToTheStockNotTheFile() {
        // A file can keep several stocks. A marker anywhere in
        // it would silently exempt a future one that could be reasoned; that
        // is the class
        // „die Ausnahme ist grobkoerniger als der gepruefte Gegenstand".
        let two = """
            struct A {
                // \(Self.marker) ein reines Inventar
                nonisolated static let alt: [String: Int] = [
                    "Foo.swift": 1,
                    "Bar.swift": 2,
                ]

                nonisolated static let neu: [String: Int] = [
                    "Baz.swift": 1,
                    "Qux.swift": 2,
                ]
            }
            """
        let stocks = Self.fileStocks(in: two)
        #expect(stocks.count == 2)
        #expect(stocks.first?.excused == true)
        #expect(stocks.last?.excused == false, "der Merker des ersten Bestands befreit den zweiten mit")
    }
}
#endif
