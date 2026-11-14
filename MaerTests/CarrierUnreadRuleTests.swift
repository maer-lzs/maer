// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Over rows the start could not read, every carrier forgets its token or
/// version and takes the rows once read through ONE place
/// (`CarrierRows.forgetUntilRead`), the run winning per entry
/// (`CarrierRows.laterRead`).
struct CarrierUnreadRuleTests {
    @Test("late-read rows fill only what the run does not know; the run wins per entry")
    func theRunWinsPerEntry() {
        let read = ["a": [1.0], "b": [2.0]]
        let run = ["b": [9.0], "c": [3.0]]
        #expect(CarrierStandRows.laterRead(read, under: run) == ["a": [1.0], "b": [9.0], "c": [3.0]])
        #expect(CarrierStandRows.laterRead(read, under: [:]) == read, "a run that learned nothing takes the rows")
        #expect(CarrierStandRows.laterRead([String: [Double]](), under: run) == run)
    }

    /// Where the carriers' sources say the rule, in comment-free code.
    static func sites(of token: String) throws -> [String: Int] {
        var found: [String: Int] = [:]
        for file in SourceTree.files(under: SourceTree.root.appendingPathComponent("Sources")) where file.pathExtension == "swift" {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            let count = code.components(separatedBy: token).count - 1
            if count > 0 { found[file.lastPathComponent, default: 0] += count }
        }
        return found
    }

    @Test("every carrier states the rule about unread rows in the one place", .needsTheSources)
    func everyCarrierUsesTheOnePlace() throws {
        let rule = try Self.sites(of: ".forgetUntilRead(")
        #expect(rule == ["CloudKitStandCarrier.swift": 1, "CloudKitPlaylistCarrier.swift": 1, "CloudKitStatsCarrier.swift": 1,
                         "CloudKitChoiceCarrier.swift": 1, "MaerSyncCarriers.swift": 2],
                "the six carriers of the rule: \(rule)")
        // The stamps of the choices wait for their rows too, but hold no
        // token or version to forget.
        let waits = try Self.sites(of: ".whenRead")
        #expect(waits == ["UserChoiceCloudSync.swift": 2], "a carrier waits for its rows past the rule: \(waits)")
        let merges = try Self.sites(of: "in run }")
        #expect(merges == ["CarrierRows.swift": 1], "a carrier merges read rows on its own: \(merges)")
    }
}
#endif
