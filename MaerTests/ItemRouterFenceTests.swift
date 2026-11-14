// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import SwiftUI
@testable import Maer

/// GOAL 3.0 point 3, second slice: the address of a cover is ASKED for,
/// not built by oneself. The STOCK carries most of it: which surfaces still
/// ask the session for a cover address themselves, per file, with a reason.
///
/// In addition a statement about the setting sites, but for a different reason
/// than with the network value. There it held the CORRECTNESS (a forgotten
/// pass-along would have stayed silent); here a forgotten pass-along is
/// harmless, because the default value is the real router. Here it holds the
/// COST: `ItemRouter` carries a closure and is therefore not
/// comparable. Whoever sets it in a `body` builds a new value on every pass
/// that SwiftUI cannot recognize as equal, and all
/// readers below are re-evaluated. As long as only the default value applies,
/// nothing is ever compared and nothing invalidated.
struct ItemRouterFenceTests {
    /// The five questions of the sheet, as they are named on the session.
    private static let questions = ["AppSession.shared.coverURL",
                                    "AppSession.shared.libraryItem",
                                    "AppSession.shared.playableItem",
                                    "AppSession.shared.provider(",
                                    "AppSession.shared.resolve("]

    static func reaches(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && questions.contains { trimmed.contains($0) }
            }.count
    }

    /// The views that still ask the session one of the five questions, each
    /// with its reason in its entry. Empty, measured: the four helpers of
    /// the day the fence was built lost their grips, and the door itself
    /// asks through its own handle (`liveSession`), which this finder does
    /// not read. A new grip in the spelled form is red; a grip through a
    /// handle of its own is not seen here.
    nonisolated static let stock: [String: (count: Int, reason: String)] = [:]

    @Test("The router sheet is asked only in the stock itself", .needsTheSources)
    func theRouterLeafIsAskedForNotBuilt() throws {
        var counts: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            counts[file.lastPathComponent, default: 0] += Self.reaches(in: try String(contentsOf: file, encoding: .utf8))
        }
        // Per file both ways, so the total is the stock's total as well.
        let drift = StockDrift.findings(counts: counts, stock: Self.stock.mapValues(\.count))
        #expect(drift.isEmpty, "a view asks the session itself again, or a stock above the count: \(drift)")
        // Red probe in both directions, over all five questions: the
        // checker sees every grip…
        #expect(Self.reaches(in: "let u = AppSession.shared.coverURL(forItemId: id)") == 1)
        #expect(Self.reaches(in: "let i = AppSession.shared.libraryItem(forId: id)") == 1)
        #expect(Self.reaches(in: "let p = AppSession.shared.provider(for: id)") == 1)
        // …and a comment about a grip it does NOT see.
        #expect(Self.reaches(in: "// was AppSession.shared.coverURL(forItemId:)") == 0)
    }

    /// The count stands as a function so that the red probe runs through THE
    /// CHECKER and not through `String.contains`. A probe that does not
    /// call the checker stays green if tomorrow someone breaks the pattern
    /// or the cutting off.
    static func setters(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains(".environment(\\.itemRouter")
            }.count
    }

    @Test("Nobody sets the router in the program, or all readers cost", .needsTheSources)
    func nobodyHandsTheRouterDownInTheApp() throws {
        var setters: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let count = Self.setters(in: try String(contentsOf: file, encoding: .utf8))
            if count > 0 { setters.append("\(file.lastPathComponent): \(count)") }
        }
        // The fence sees only `Sources`. A preview or a witness sets
        // the router outside a body and does not fall under it;
        // that is the exception that needs no rule.
        #expect(setters.isEmpty,
                """
                der Router wird im Programm gesetzt (\(setters)). Er traegt einen \
                Verschluss und ist nicht vergleichbar: in einem `body` gesetzt \
                entsteht je Durchlauf ein neuer Wert, und ALLE Leser darunter \
                werden neu ausgewertet. Wer ihn wirklich reichen muss, macht ihn \
                vorher vergleichbar oder haelt ihn ausserhalb des Koerpers
                """)
        // Red probe in both directions, through the checker: it would see the
        // form if it came…
        #expect(Self.setters(in: "content.environment(\\.itemRouter, ItemRouter())") == 1)
        // …and a comment about it it does NOT see.
        #expect(Self.setters(in: "// never .environment(\\.itemRouter, …)") == 0)
    }

    @Test("The default value is the REAL router, a forgotten pass-along breaks nothing")
    func theDefaultIsTheRealRouter() {
        // Unlike with the network value there would be no harmless substitute here:
        // a router that knows nothing returns no address, and images
        // would silently stay away. That is why the default is the real one, as with
        // the environment actions of SwiftUI itself.
        let fromEnvironment = EnvironmentValues().itemRouter
        // The default value ANSWERS. The case needs an id whose
        // provider answers WITHOUT session state, otherwise it checks nothing:
        // a radio id would give nil here, because during the run nobody knows the
        // station, and `nil == nil` would pass an empty
        // substitute router too. An archive id derives the address PURELY from
        // the id.
        let derived = fromEnvironment.coverURL("\(FreeCatalog.archivePrefix)beispielwerk")
        #expect(derived != nil)
        #expect(derived?.absoluteString.contains("beispielwerk") == true)
        // And the rule of the session still applies: an id from an
        // unknown namespace gets no address (the protection that ended the
        // 404 storm).
        #expect(fromEnvironment.coverURL("quatsch:42") == nil)
        // Being replaceable IS the gain of this slice, so it stands as a
        // case: a substituted router answers differently, and an
        // empty one fails at the first assertion.
        let stub = ItemRouter(coverURL: { _ in URL(string: "https://example.org/x.jpg") })
        #expect(stub.coverURL("egal")?.host() == "example.org")
        let empty = ItemRouter(coverURL: { _ in nil })
        #expect(empty.coverURL("\(FreeCatalog.archivePrefix)beispielwerk") == nil)
    }
}
#endif
