// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Der Traegerwechsel, bevor etwas getragen wird: passt es, und was kostet
/// es. Beide Fragen entscheiden, ob der Rueckweg bei den Leuten mit viel
/// Bestand funktioniert, und beide muessen VOR dem ersten Schrieb
/// beantwortet sein.
struct CarrierHandoverTests {

    // MARK: - Der Anspruch reist nicht

    @Test("der Anspruch ist KEINE Familie, und das ist keine Auslassung")
    func theClaimIsNotAFamily() {
        let names = CarrierHandover.Family.allCases.map(\.rawValue).sorted()
        #expect(names == ["choices", "feedAuth", "playlists", "stands", "stats"])
        // Er sagt, welches Geraet gerade spielt, altert in seinem eigenen
        // Takt weg, und ein mitgeschleppter alter Anspruch wuerde ein
        // Geraet ankuendigen, das laengst aufgehoert hat.
        #expect(!names.contains("claim"))
    }

    // MARK: - Die Decke, und ein abgewiesener Schrieb ist still

    @Test("zum Dienst gibt es keine Decke")
    func theServiceHasNoCeiling() {
        #expect(CarrierHandover.room(states: 100_000, subscriptions: 5_000,
                                     target: .service) == .fits)
    }

    @Test("zu Apple gilt sie nur, solange der Rueckfall traegt")
    func appleHasItOnlyWhileTheFallbackCarries() {
        // Ohne Decke (die Wolke selbst hat keine) passt auch viel.
        #expect(CarrierHandover.room(states: 100_000, subscriptions: 5_000,
                                     target: .apple(hasRoomLimit: false)) == .fits)
    }

    @Test("rund achttausend Staende fuellen das Megabyte, und dann wird laut abgelehnt")
    func eightThousandStatesFillTheMegabyte() {
        // Gemessen an einem echten Topf: 124 Byte je Stand. Die Zahl steht
        // nicht hier, sie kommt aus der Stelle, die sie gemessen hat.
        #expect(CarrierHandover.bytesPerState == 124)
        #expect(CarrierHandover.potLimitBytes == 1_000_000)
        let justUnder = CarrierHandover.potLimitBytes / CarrierHandover.bytesPerState
        #expect(justUnder == 8064)
        #expect(CarrierHandover.room(states: justUnder, subscriptions: 0,
                                     target: .apple(hasRoomLimit: true)) == .fits)
        // Einer mehr, und es ist vorbei. Das Entscheidende ist nicht die
        // Grenze, sondern dass sie GESAGT wird: der Speicher nimmt einen
        // Schrieb, den er nicht will, schweigend nicht an.
        guard case .tooLarge(let needs, let limit) =
                CarrierHandover.room(states: justUnder + 1, subscriptions: 0,
                                     target: .apple(hasRoomLimit: true)) else {
            Issue.record("haette abgelehnt werden muessen"); return
        }
        #expect(needs > limit)
        #expect(limit == 1_000_000)
    }

    @Test("die Abos zaehlen mit, nicht nur die Staende")
    func subscriptionsCountToo() {
        // 180 Byte je Abo im Wahlen-Blob, ebenfalls an der plist gemessen.
        // Wer nur die Staende rechnet, faellt bei jemandem mit vielen
        // Sendungen in dieselbe Stille.
        let states = 7_000
        #expect(CarrierHandover.room(states: states, subscriptions: 0,
                                     target: .apple(hasRoomLimit: true)) == .fits)
        guard case .tooLarge = CarrierHandover.room(states: states, subscriptions: 1_000,
                                                    target: .apple(hasRoomLimit: true)) else {
            Issue.record("tausend Abos sind 180 000 Byte und muessen kippen"); return
        }
    }

    // MARK: - Sechs Schriebe gegen zwanzig Stapel

    @Test("zum Dienst ist ein Vollabgleich eine Handvoll Schriebe, unabhaengig vom Bestand")
    func towardsTheServiceItIsAHandful() {
        #expect(CarrierHandover.writes(states: 0, target: .service) == 5)
        #expect(CarrierHandover.writes(states: 8_000, target: .service) == 5)
        // Ein Ganz-Dokument ist EIN Schrieb, gleich wie viel darin steht.
        #expect(CarrierHandover.writes(states: 100_000, target: .service) == 5)
    }

    @Test("zu Apple waechst er mit dem Bestand, in Stapeln zu vierhundert")
    func towardsAppleItGrowsInBatches() {
        #expect(CarrierHandover.recordsPerBatch == 400)
        let target = CarrierHandover.Target.apple(hasRoomLimit: false)
        // Vier Familien als Ganzes plus die Stapel des Topfs.
        #expect(CarrierHandover.writes(states: 0, target: target) == 5)
        #expect(CarrierHandover.writes(states: 400, target: target) == 5)
        #expect(CarrierHandover.writes(states: 401, target: target) == 6)
        #expect(CarrierHandover.writes(states: 8_000, target: target) == 24)
    }

    @Test("die Sichtbarkeit richtet sich nach der TEUREN Richtung")
    func visibilityFollowsTheExpensiveDirection() {
        // Ein Anteil der billigen Richtung waere eine Zahl, die bei der
        // teuren nach Stillstand aussieht. Also sagt die Regel, WANN ueber
        // Stapel zu reden ist, statt dass die Flaeche es errät.
        #expect(!CarrierHandover.showsBatches(states: 8_000, target: .service))
        #expect(!CarrierHandover.showsBatches(states: 10,
                                              target: .apple(hasRoomLimit: false)))
        #expect(CarrierHandover.showsBatches(states: 8_000,
                                             target: .apple(hasRoomLimit: false)))
    }

    @Test("die Byte-Zahlen werden NICHT zweimal erfunden")
    func theByteNumbersAreNotInventedTwice() {
        // Sie kommen aus der Stelle, die sie an einem echten Topf gemessen
        // hat. Eine zweite Kopie waere eine zweite Wahrheit, die beim
        // naechsten Nachmessen nur an einer Stelle berichtigt wird.
        #expect(CarrierHandover.bytesPerState == ForeignImportPreview.bytesPerState)
        #expect(CarrierHandover.bytesPerSubscription == ForeignImportPreview.bytesPerSubscription)
        #expect(CarrierHandover.potLimitBytes == ForeignImportPreview.potLimitBytes)
    }
}
#endif
