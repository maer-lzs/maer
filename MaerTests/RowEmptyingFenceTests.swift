// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every row write says whether emptying the stock is its action. The
/// compiler forces a word at every write; this fence holds which writes may
/// empty: each one stands in the stock with its reason, in both directions.
struct RowEmptyingFenceTests {
    /// The writes that may empty a row store, per file, with the reason.
    nonisolated static let allowedStock: [String: (count: Int, reason: String)] = [
        "SyncQueue.swift": (1, "a sent entry leaves the queue; one that stayed would be sent again"),
        "DownloadManager.swift": (1, "the marks leave with the deleted downloads, the last one too"),
        "LocalLibrary.swift": (1, "the user deleted the item"),
        "MaerPlaylists.swift": (2, "the user deleted the list; the merge carries the account's removal marks"),
        "PodcastSubscriptions.swift": (2, "the person's own unsubscribe, the last one too, here or as a tombstone from another device"),
    ]

    /// The writes in `code` that may empty, as written.
    nonisolated static func allowedWrites(in code: String) -> Int {
        code.matches(of: #/emptying:\s*(?:RowEmptying)?\.allowed/#).count
    }

    @Test("jede Zeilen-Schrift, die leeren darf, steht mit Grund im Bestand, in beide Richtungen", .needsTheSources)
    func onlyTheStockMayEmpty() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.contains { $0.lastPathComponent == "RowKeeper.swift" }, "the fence read the sources")
        var found: [String: Int] = [:]
        for file in files {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            let n = Self.allowedWrites(in: code)
            if n > 0 { found[file.lastPathComponent] = n }
        }
        #expect(found == Self.allowedStock.mapValues(\.count), "writes that may empty outside the stock or left it: \(found)")
        // Calibration: both spellings count, the declaration does not.
        #expect(Self.allowedWrites(in: "a.write(x, emptying: .allowed)\nb(emptying: RowEmptying.allowed)") == 2)
        #expect(Self.allowedWrites(in: "case allowed\nwrite(x, emptying: .refused)") == 0)
    }

    /// The stores with a write chain of their own ask the same rule as the
    /// keeper (`previous(for:)`, `refuses`), and no source diffs against
    /// nothing by hand any more: that form forgot what the start read. The
    /// playlists and the listen log write through a keeper now.
    nonisolated static let ownChains = ["RowKeeper.swift", "ListeningStats.swift", "PodcastSubscriptions.swift"]

    nonisolated static func diffsAgainstNothing(_ code: String) -> Bool {
        code.contains(#/apply\(previous:\s*\[:\]|knownValue\s*\?\?\s*(?:\[:?\]|ListeningStatsData\(\)|removable|\(?base\.removable)/#)
    }

    @Test("jede eigene Schreibkette fragt die eine Regel, und keine Quelle vergleicht von Hand gegen nichts", .needsTheSources)
    func everyChainAsksTheRule() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var asking: Set<String> = []
        var byHand: [String] = []
        for file in files {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains(".previous(for:"), code.contains(".refuses(") { asking.insert(file.lastPathComponent) }
            if Self.diffsAgainstNothing(code) { byHand.append(file.lastPathComponent) }
        }
        #expect(Set(Self.ownChains).isSubset(of: asking), "a chain does not ask the rule: \(Set(Self.ownChains).subtracting(asking).sorted())")
        #expect(byHand.isEmpty, "diffs against nothing by hand: \(byHand)")
        // Calibration: the form the keeper had before.
        #expect(Self.diffsAgainstNothing("_ = try await rows.apply(previous: [:], current: snapshot)"))
        #expect(Self.diffsAgainstNothing("rows.apply(previous: base.knownValue ?? [:], current: s)"))
        #expect(!Self.diffsAgainstNothing("rows.apply(previous: base.previous(for: s), current: s)"))
        // And the forms the subscriptions had before.
        #expect(Self.diffsAgainstNothing("compute(previous: base.knownValue ?? [], current: snapshot)"))
        #expect(Self.diffsAgainstNothing("let previous = base.knownValue ?? removable.filter { _ in true }"))
    }
}
#endif
