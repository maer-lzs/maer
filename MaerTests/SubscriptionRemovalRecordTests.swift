// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// An unsubscribe with the sync switched OFF was lost: `note` stores in
/// this branch only the event TIME, and for subscriptions the statement is
/// deliberately not derivable from the local stock. At the next
/// switch-on the older „abonniert" statement from the cloud won, and the
/// takeover brought the show back.
///
/// The answer is NOT to derive it after all. The danger named in the comment of
/// the storage („nicht im Speicher" also means „noch nicht uebernommen") comes from
/// GUESSING, not from remembering.
struct SubscriptionRemovalRecordTests {
    @Test("A recorded removal is spoken")
    func arecordedRemovalIsStated() {
        let pending = SubscriptionRemovalRecord.pending(recorded: ["feed-a": 100],
                                                        subscribedKeys: [])
        #expect(pending == ["feed-a": 100])
    }

    /// The actual safeguard: whoever unsubscribes with the sync switched off
    /// and THEN subscribes again must not be overtaken by their own older
    /// statement.
    @Test("A new subscription of the same address deletes the statement")
    func aFreshSubscribeSilencesTheRecord() {
        let pending = SubscriptionRemovalRecord.pending(recorded: ["feed-a": 100, "feed-b": 100],
                                                        subscribedKeys: ["feed-a"])
        #expect(pending == ["feed-b": 100])
    }

    @Test("What the cloud already carries is forgotten")
    func whatTheCloudCarriesIsForgotten() {
        let settled = SubscriptionRemovalRecord.settled(
            recorded: ["gleich": 100, "neuer": 100, "aelter": 100],
            cloudRemovalTimes: ["gleich": 100, "neuer": 200, "aelter": 50])
        // „Mindestens so neu": another device may have removed the same show
        // later, then its statement says the same with the
        // better time.
        #expect(settled == ["gleich", "neuer"])
    }

    @Test("Without a statement in the cloud the record stays")
    func withoutACloudStatementTheRecordStays() {
        #expect(SubscriptionRemovalRecord.settled(recorded: ["feed-a": 100],
                                                  cloudRemovalTimes: [:]).isEmpty)
        // And a SUBSCRIPTION in the cloud is no removal: the caller passes in
        // only removals, but the case pins down that an empty
        // list consumes nothing.
        #expect(SubscriptionRemovalRecord.settled(recorded: ["feed-a": 100],
                                                  cloudRemovalTimes: ["anderer": 999]).isEmpty)
    }

    /// The stock: the DERIVATION stays refused. Had it
    /// come back, the whole move would be pointless and dangerous, and no
    /// behaviour case would notice, because both ways would have the same result
    /// as long as nothing goes wrong.
    @Test("The derivation of a subscription tombstone stays refused", .needsTheSources)
    func theDerivationStaysRefused() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent("Sources/Networking/UserChoiceCloudSync.swift"),
                              encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("if key.hasPrefix(UserChoiceCatalog.subscriptionPrefix) { continue }"),
                "die Schleife leitet wieder Abo-Grabsteine aus Stempeln ab")
        // And the record is the place that speaks instead.
        #expect(code.contains("SubscriptionRemovalRecord.pending("),
                "die aufgezeichneten Entfernungen werden nicht mehr ausgesprochen")
        #expect(code.contains("SubscriptionRemovalRecord.settled("),
                "die Aufzeichnungen werden nie verbraucht und wiederholen sich ewig")
    }
}
#endif
