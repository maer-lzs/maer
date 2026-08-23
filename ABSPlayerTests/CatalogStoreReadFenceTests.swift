// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// R39: the class "a surface reads the catalog store without anything
/// starting its load" came back — the 10.08. fence was gone from the tree,
/// so it held nothing. This time the rule is CONSTRUCTIONAL (reading `rows`
/// starts the pass) and the fence guards the construction itself, not a
/// list of call sites: nobody may read the stored rows directly.
struct CatalogStoreReadFenceTests {

    private func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(files.count > 50, "the sweep must see the tree, not an empty folder")
        return try files.map { (name: $0.lastPathComponent,
                                text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("no surface reads the STORED rows — reading goes through the loading getter")
    func noSurfaceReadsStoredRowsDirectly() throws {
        var offenders: [String] = []
        for file in try sources() where file.name != "FreeCatalogRows.swift" {
            if file.text.contains("storedRows") || file.text.contains("storedSourceRows") {
                offenders.append(file.name)
            }
        }
        #expect(offenders.isEmpty,
                "these read the stored rows and would bypass the load: \(offenders)")
    }

    @Test("the fence would SEE a bypass (red probe)")
    func fenceCatchesABypass() {
        let bypass = "ForEach(freeCatalogStore.storedRows.freeMusic) { item in }"
        #expect(bypass.contains("storedRows"))
    }

    /// R40: a catalog row may exist ONCE per surface. The duplicate arose
    /// because a repair was made at the REPORTED spot without sweeping the
    /// same file for a sibling row of the same source — and the two then
    /// carried different conditions, so the area switch (a PRIVACY switch)
    /// was without effect. Counting the row's own tile call per file is the
    /// mechanical version of that sweep.
    @Test("each catalog row is rendered once per surface")
    func noDuplicateCatalogRow() throws {
        for file in try sources() {
            for row in ["rows.freeMusic", "rows.netlabels", "rows.tabBooks"] {
                let renders = file.text.components(separatedBy: "freeTileRow(\(row)")
                    .count - 1 + file.text.components(separatedBy: "tileRow(\(row)").count - 1
                #expect(renders <= 1,
                        "\(file.name) renders \(row) \(renders)× — two rows, one source")
            }
        }
    }

    /// The second half of the same class: an INCOMPLETE pass must leave the
    /// door open, or a reading surface is refused for the whole session
    /// ("already attempted") although nothing was ever delivered.
    @Test("an incomplete pass reopens the gate — bounded, so no render loop")
    func incompletePassReopensBounded() {
        var gate = CatalogLoadGate()
        var started = gate.startIfNeeded(connected: true)
        #expect(started)
        gate.finish()
        // Without the reopen the next reading surface is refused …
        started = gate.startIfNeeded(connected: true)
        #expect(!started)
        gate.reopenForIncompletePass()
        started = gate.startIfNeeded(connected: true)
        #expect(started, "a cancelled pass must be retryable")
        gate.finish()
        // … and the retries are bounded (the empty-pass render loop is why
        // this gate exists at all).
        for _ in 0..<10 { gate.reopenForIncompletePass() }
        #expect(gate.incompleteRetries == CatalogLoadGate.incompleteRetryLimit)
        var exhausted = CatalogLoadGate()
        for _ in 0..<CatalogLoadGate.incompleteRetryLimit {
            _ = exhausted.startIfNeeded(connected: true)
            exhausted.finish()
            exhausted.reopenForIncompletePass()
        }
        _ = exhausted.startIfNeeded(connected: true)
        exhausted.finish()
        exhausted.reopenForIncompletePass()
        let refused = !exhausted.startIfNeeded(connected: true)
        #expect(refused, "after the limit only an EXPLICIT path may reopen")
    }
}
#endif
