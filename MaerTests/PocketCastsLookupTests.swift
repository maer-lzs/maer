// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// D3 b, the asking round: every state without a handle is asked for
/// once, within the budget, one request after the other; 404 is a clean
/// "not known" and the round goes on; a refusal (429, 5xx), another
/// status, an unreachable host or an unknown shape ends the round with
/// its name, and the import runs on without it.
struct PocketCastsLookupTests {
    private func answer(_ uuid: String, title: String? = "T", url: String? = "https://cdn.example.invalid/x.mp3") -> Data {
        var row: [String: Any] = ["uuid": uuid]
        if let title { row["title"] = title }
        if let url { row["url"] = url }
        return try! JSONSerialization.data(withJSONObject: row)
    }

    @Test("jede fehlende Folge einmal, im Deckel, in Reihenfolge; 404 laeuft weiter")
    func asksEachOnceWithinBudget() async {
        var seen: [String] = []
        let round = await PocketCastsClient.lookupRound(uuids: ["a", "b", "c", "d"], budget: 3) { uuid in
            seen.append(uuid)
            if uuid == "b" { return (Data(), 404) }
            return (answer(uuid, url: uuid == "c" ? nil : "https://cdn.example.invalid/\(uuid).mp3"), 200)
        }
        #expect(seen == ["a", "b", "c"], "the budget of three leaves d unasked")
        #expect(round.asked == 3)
        #expect(round.answered == 2)
        #expect(round.titled == 2)
        #expect(round.addressed == 1)
        #expect(round.status == "ok")
        #expect(round.details.map(\.uuid) == ["a", "c"])
    }

    @Test("429 oder 5xx beendet die Runde mit dem Status, das Gefragte bleibt gezaehlt")
    func refusalEndsTheRound() async {
        var seen: [String] = []
        let throttled = await PocketCastsClient.lookupRound(uuids: ["a", "b", "c"], budget: 300) { uuid in
            seen.append(uuid)
            return uuid == "b" ? (Data(), 429) : (answer(uuid), 200)
        }
        #expect(seen == ["a", "b"])
        #expect(throttled.asked == 2 && throttled.answered == 1)
        #expect(throttled.status == "429")
        let down = await PocketCastsClient.lookupRound(uuids: ["a"], budget: 300) { _ in (Data(), 503) }
        #expect(down.status == "503" && down.answered == 0)
        let forbidden = await PocketCastsClient.lookupRound(uuids: ["a", "b"], budget: 300) { _ in (Data(), 403) }
        #expect(forbidden.status == "403" && forbidden.asked == 1)
    }

    @Test("unbekannte Form und unerreichbarer Host beenden die Runde, nichts wird geraten")
    func unknownShapeAndUnreachableEndTheRound() async {
        let shape = await PocketCastsClient.lookupRound(uuids: ["a", "b"], budget: 300) { _ in
            (Data("{\"result\":\"something else\"}".utf8), 200)
        }
        #expect(shape.status == "decode" && shape.asked == 1 && shape.details.isEmpty)
        struct Down: Error {}
        let unreachable = await PocketCastsClient.lookupRound(uuids: ["a", "b"], budget: 300) { _ in throw Down() }
        #expect(unreachable.status == "unreachable" && unreachable.asked == 1)
        let none = await PocketCastsClient.lookupRound(uuids: [], budget: 300) { _ in (Data(), 200) }
        #expect(none == PocketCastsClient.LookupOutcome())
        let spent = await PocketCastsClient.lookupRound(uuids: ["a"], budget: 0) { _ in (Data(), 200) }
        #expect(spent.asked == 0)
    }

    @Test("der Deckel je Import ist dreihundert")
    func capIsThreeHundred() {
        #expect(PocketCastsClient.lookupCap == 300)
    }
}
#endif
