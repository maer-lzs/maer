// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Ein Abbestellen bei AUSGESCHALTETEM Abgleich ging verloren: `note` legt in
/// diesem Zweig nur die Ereignis-ZEIT ab, und fuer Abos ist die Aussage
/// absichtlich nicht aus dem lokalen Bestand herleitbar. Beim naechsten
/// Einschalten gewann die aeltere „abonniert"-Aussage aus der Wolke, und die
/// Uebernahme holte die Sendung zurueck.
///
/// Die Antwort ist NICHT, sie doch herzuleiten. Die Gefahr im Kommentar der
/// Ablage („nicht im Speicher" heisst auch „noch nicht uebernommen") kommt vom
/// RATEN, nicht vom Erinnern.
struct SubscriptionRemovalRecordTests {
    @Test("Eine aufgezeichnete Entfernung wird ausgesprochen")
    func arecordedRemovalIsStated() {
        let pending = SubscriptionRemovalRecord.pending(recorded: ["feed-a": 100],
                                                        subscribedKeys: [])
        #expect(pending == ["feed-a": 100])
    }

    /// Die eigentliche Sicherung: wer bei ausgeschaltetem Abgleich abbestellt
    /// und DANN wieder abonniert, darf nicht von seiner eigenen aelteren
    /// Aussage ueberholt werden.
    @Test("Ein neues Abo derselben Adresse loescht die Aussage")
    func aFreshSubscribeSilencesTheRecord() {
        let pending = SubscriptionRemovalRecord.pending(recorded: ["feed-a": 100, "feed-b": 100],
                                                        subscribedKeys: ["feed-a"])
        #expect(pending == ["feed-b": 100])
    }

    @Test("Was die Wolke schon traegt, wird vergessen")
    func whatTheCloudCarriesIsForgotten() {
        let settled = SubscriptionRemovalRecord.settled(
            recorded: ["gleich": 100, "neuer": 100, "aelter": 100],
            cloudRemovalTimes: ["gleich": 100, "neuer": 200, "aelter": 50])
        // „Mindestens so neu": ein anderes Geraet kann dieselbe Sendung
        // spaeter entfernt haben, dann sagt seine Aussage dasselbe mit der
        // besseren Zeit.
        #expect(settled == ["gleich", "neuer"])
    }

    @Test("Ohne Aussage in der Wolke bleibt die Aufzeichnung stehen")
    func withoutACloudStatementTheRecordStays() {
        #expect(SubscriptionRemovalRecord.settled(recorded: ["feed-a": 100],
                                                  cloudRemovalTimes: [:]).isEmpty)
        // Und ein ABO in der Wolke ist keine Entfernung: der Aufrufer reicht
        // nur Entfernungen herein, aber der Fall haelt fest, dass eine leere
        // Liste nichts verbraucht.
        #expect(SubscriptionRemovalRecord.settled(recorded: ["feed-a": 100],
                                                  cloudRemovalTimes: ["anderer": 999]).isEmpty)
    }

    /// Der Bestand: die HERLEITUNG bleibt verweigert. Waere sie
    /// zurueckgekommen, waere der ganze Zug sinnlos und gefaehrlich, und kein
    /// Verhaltens-Fall wuerde es merken, weil beide Wege dasselbe Ergebnis
    /// haetten, solange nichts schiefgeht.
    @Test("Die Ableitung eines Abo-Grabsteins bleibt verweigert")
    func theDerivationStaysRefused() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent("Sources/Networking/UserChoiceCloudSync.swift"),
                              encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("if key.hasPrefix(UserChoiceCatalog.subscriptionPrefix) { continue }"),
                "die Schleife leitet wieder Abo-Grabsteine aus Stempeln ab")
        // Und die Aufzeichnung ist die Stelle, die stattdessen spricht.
        #expect(code.contains("SubscriptionRemovalRecord.pending("),
                "die aufgezeichneten Entfernungen werden nicht mehr ausgesprochen")
        #expect(code.contains("SubscriptionRemovalRecord.settled("),
                "die Aufzeichnungen werden nie verbraucht und wiederholen sich ewig")
    }
}
#endif
