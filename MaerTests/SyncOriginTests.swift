// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every position write of the player names its occasion. Before, only
/// "forced or not" arrived, and no witness could tell a pause from a seek.
struct SyncOriginTests {
    @Test("nur der Tick ist nicht bewusst, genau wie frueher nur der Tick nicht forciert war")
    func onlyTheTickIsNotDeliberate() {
        #expect(SyncOrigin.allCases.filter { !$0.isDeliberate } == [.tick])
        #expect(SyncOrigin.allCases.count == 11, "elf Anlaesse, einer je Rufer")
    }

    /// The callers that pass on an occasion a caller above already named,
    /// by their argument, each with its reason. They count as `forwarded`.
    nonisolated static let forwarders: [String: String] = [
        "origin": "the follow-up of a mark runs the occasion that asked while the mark held the guard (MarkFollowUp)",
    ]

    /// The occasion each call of `syncProgress` names, counted over the
    /// sources. A call that passes anything but a named occasion or a named
    /// forwarder counts as `"?"`, the former `force:` form among them.
    /// Comments go first; the argument is read across a line break.
    nonisolated static func origins(in text: String) -> [String: Int] {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(IdQuestionDoorFenceTests.withoutComment($0)) }
            .joined(separator: "\n")
            .replacing(#/func\s+syncProgress\(/#, with: "func declaration(")
        var found: [String: Int] = [:]
        // No `\b`: under Unicode word rules `self.syncProgress` is ONE word
        // (a dot between letters does not break it), so the calls with a
        // receiver would slip through.
        for match in code.matches(of: #/(?:^|[^A-Za-z0-9_])syncProgress\(\s*([^)]*)\)/#) {
            let argument = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
            if forwarders[argument] != nil {
                found["forwarded", default: 0] += 1
                continue
            }
            let name = argument.hasPrefix(".") ? String(argument.dropFirst()) : "?"
            found[SyncOrigin(rawValue: name) != nil ? name : "?", default: 0] += 1
        }
        return found
    }

    /// Measured: every occasion is named by exactly one caller. A new
    /// caller takes its own occasion or shows up here.
    @Test("jeder Rufer nennt seinen Anlass, jeder Anlass hat genau einen Rufer", .needsTheSources)
    func everyCallerNamesItsOccasion() throws {
        let files = ProjectFileIntegrityTests.sourceFiles()
        try #require(files.count > 300, "der Zeuge hat den Quelltext nicht gelesen")
        var found: [String: Int] = [:]
        for file in files {
            found.merge(Self.origins(in: try String(contentsOf: file, encoding: .utf8))) { $0 + $1 }
        }
        let expected = Dictionary(uniqueKeysWithValues: SyncOrigin.allCases.map { ($0.rawValue, 1) })
            .merging(["forwarded": Self.forwarders.count]) { $1 }
        #expect(found == expected, "Anlaesse der Rufer: \(found.sorted { $0.key < $1.key })")
        #expect(Self.origins(in: "await syncProgress(origin)") == ["forwarded": 1],
                "ein benannter Weiterreicher zaehlt als solcher")
        #expect(Self.origins(in: "await syncProgress(someOrigin)") == ["?": 1],
                "ein anderer Weiterreicher bleibt ungenannt")
        #expect(Self.origins(in: "Task { await syncProgress(force: true) }") == ["?": 1],
                "die fruehere Form zaehlt als ungenannt")
        #expect(Self.origins(in: "await self.syncProgress(\n    .pause)") == ["pause": 1],
                "der Zaehler liest den Anlass auch ueber einen Umbruch")
        #expect(Self.origins(in: "func syncProgress(_ origin: SyncOrigin) async {").isEmpty,
                "die Erklaerung ist kein Rufer")
        #expect(Self.origins(in: "// syncProgress(.pause)").isEmpty, "ein Kommentar ruft nicht")
    }
}
#endif
