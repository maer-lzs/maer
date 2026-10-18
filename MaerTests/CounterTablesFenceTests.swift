// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every keyed table either holds a whole value per key (a write replaces
/// the row) or sums (a write adds this run's counting to what the row
/// holds). A summing table written before its rows were read would replace
/// the stock with one run's numbers, so its store must hold the write lock
/// `rowsReadForWrite`. A new table without a sort turns this red.
struct CounterTablesFenceTests {
    enum Kind { case wholeValue, summed }

    /// Every table, sorted, with the reason in the entry.
    nonisolated static let kinds: [String: (kind: Kind, reason: String)] = [
        "listen_log": (.wholeValue, "one entry per episode, merged before the write"),
        "stats_day": (.summed, "seconds per day, this run's counting added to the stock"),
        "stats_item": (.summed, "seconds per title, this run's counting added to the stock"),
        "maer_playlist": (.wholeValue, "one playlist per key"),
        "play_queue": (.wholeValue, "the one Up Next list"),
        "playback_context": (.wholeValue, "the one playback context"),
        "pending_sync": (.wholeValue, "the newest pending update per title"),
        "sync_history": (.wholeValue, "one history entry per key"),
        "sync_last_checked": (.wholeValue, "one stamp per service"),
        "local_library": (.wholeValue, "one local title per key"),
        "download_meta": (.wholeValue, "one finished download per book"),
        "listen_history": (.wholeValue, "one entry per book or song, merged before the write"),
        "carrier_stand": (.wholeValue, "one stand per owner and title, as the carrier holds it"),
        "carrier_record": (.wholeValue, "one record row per owner and key, as the carrier holds it"),
    ]

    @Test("jede Tabelle ist eingeordnet, keine Einordnung ohne Tabelle")
    func everyTableIsSorted() {
        let tables = Set(KeyedRowStore<Int>.Table.allCases.map(\.rawValue))
        #expect(tables.subtracting(Self.kinds.keys).isEmpty,
                "a table without a sort: \(tables.subtracting(Self.kinds.keys).sorted())")
        #expect(Set(Self.kinds.keys).subtracting(tables).isEmpty,
                "a sort without a table: \(Set(Self.kinds.keys).subtracting(tables).sorted())")
    }

    @Test("jede summierende Tabelle wird nur hinter der Lesesperre geschrieben", .needsTheSources)
    func summingTablesHoldTheLock() {
        let summed = KeyedRowStore<Int>.Table.allCases.filter { Self.kinds[$0.rawValue]?.kind == .summed }
        #expect(!summed.isEmpty, "the fence knows no summing table")
        let files = ProjectFileIntegrityTests.sourceTexts()
        for table in summed {
            let openers = files.filter { SyncContractFenceTests.stripped($0.text).contains("table: .\(table)") }
            #expect(!openers.isEmpty, "nobody opens \(table), the fence measures nothing")
            for file in openers {
                // The call, not the declaration: `func rowsReadForWrite()`
                // carries the same words and asks nothing.
                let code = SyncContractFenceTests.stripped(file.text)
                #expect(code.contains("await rowsReadForWrite()") || code.contains("await self.rowsReadForWrite()"),
                        "\(file.name) opens the summing table \(table) without asking the write lock")
            }
        }
    }
}
#endif
