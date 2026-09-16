// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Der Block der Feed-Zugaenge: seine Schrift, sein Siegel, seine
/// Zusammenfuehrung und die eine Regel, die einen bezahlten Feed schuetzt.
struct FeedAuthBlockTests {
    private func entry(_ user: String, _ password: String, at: Double) -> FeedAuthBlock.Entry {
        FeedAuthBlock.Entry(credentials: .init(user: user, password: password), at: at)
    }

    // MARK: - Die Schrift

    @Test("Rundlauf, und gleiche Eintraege geben gleiche Bytes")
    func roundTripIsStable() throws {
        let entries = ["feed-a": entry("anna", "geheim", at: 1000),
                       "feed-b": entry("bert", "auch geheim", at: 2000)]
        let data = try #require(FeedAuthBlock.encode(entries))
        guard case .entries(let back) = FeedAuthBlock.decode(data) else {
            Issue.record("nicht lesbar"); return
        }
        #expect(back == entries)
        // Sortiert geschrieben: derselbe Zustand gibt dieselben Bytes, also
        // heisst ein Unterschied wirklich eine Aenderung und nicht eine
        // andere Woerterbuch-Reihenfolge.
        #expect(FeedAuthBlock.encode(entries) == data)
    }

    @Test("ein neueres Format wird als solches gemeldet, nicht als Schrott")
    func aNewerFormatIsNamed() throws {
        let document: [String: Any] = ["v": FeedAuthBlock.format + 5, "e": [:]]
        let data = try JSONSerialization.data(withJSONObject: document)
        #expect(FeedAuthBlock.decode(data) == .newerFormat(FeedAuthBlock.format + 5))
    }

    @Test("Unlesbares ist nicht leer")
    func unreadableIsNotEmpty() {
        #expect(FeedAuthBlock.decode(Data("kein json".utf8)) == .unreadable)
        #expect(FeedAuthBlock.decode(Data()) == .unreadable)
        // Ein Block OHNE Eintragsfeld ist kaputt, nicht leer.
        let noEntries = try? JSONSerialization.data(withJSONObject: ["v": 1])
        #expect(FeedAuthBlock.decode(noEntries ?? Data()) == .unreadable)
        // Aber ein leeres Eintragsfeld ist wirklich leer.
        let empty = try? JSONSerialization.data(withJSONObject: ["v": 1, "e": [:]])
        #expect(FeedAuthBlock.decode(empty ?? Data()) == .entries([:]))
    }

    @Test("ein halber Eintrag wird uebersprungen, ein fehlender Moment nicht")
    func halfAnEntryIsSkippedButAMissingMomentIsNot() throws {
        let document: [String: Any] = ["v": 1, "e": [
            "ganz": ["u": "anna", "p": "geheim", "t": 1234.0],
            "ohne-moment": ["u": "bert", "p": "geheim"],
            "halb": ["u": "carl"],
            "fremd": "kein woerterbuch"
        ]]
        let data = try JSONSerialization.data(withJSONObject: document)
        guard case .entries(let back) = FeedAuthBlock.decode(data) else {
            Issue.record("nicht lesbar"); return
        }
        #expect(back.keys.sorted() == ["ganz", "ohne-moment"])
        #expect(back["ohne-moment"]?.at == 0, "kein Moment heisst null und verliert jeden Gleichstand")
        #expect(back["ganz"]?.at == 1234)
    }

    // MARK: - Das Siegel

    @Test("der Dienst traegt, was er nicht lesen kann")
    func theServiceCarriesWhatItCannotRead() throws {
        let code = try #require(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB"))
        let secret = Data("anna\ngeheim".utf8)
        let sealed = try #require(FeedAuthCrypto.seal(secret, code: code))
        // Das Geheimnis steht nirgends im Umschlag.
        let text = String(data: sealed, encoding: .utf8) ?? ""
        #expect(!text.contains("geheim"))
        #expect(!text.contains("anna"))
        // Und der Umschlag ist JSON, weil das Tor des Dienstes nur lesbare
        // Dokumente annimmt.
        #expect((try? JSONSerialization.jsonObject(with: sealed)) != nil)
        #expect(FeedAuthCrypto.open(sealed, code: code) == .plaintext(secret))
    }

    @Test("ein fremder Schluessel oeffnet nicht, und der Umschlag sagt das")
    func aForeignKeyDoesNotOpen() throws {
        let mine = try #require(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB"))
        let theirs = try #require(DeviceLinkCode.normalized("ZYXW-VTSR-QPNM-KJHG-FEDC-BAZY"))
        let sealed = try #require(FeedAuthCrypto.seal(Data("geheim".utf8), code: mine))
        #expect(FeedAuthCrypto.open(sealed, code: theirs) == .sealedForAnother)
        // Kein Umschlag ist etwas anderes als ein fremder Umschlag.
        #expect(FeedAuthCrypto.open(Data("kein json".utf8), code: mine) == .unreadable)
    }

    @Test("zweimal dasselbe siegeln gibt zwei verschiedene Umschlaege")
    func sealingTwiceGivesTwoEnvelopes() throws {
        let code = try #require(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB"))
        let secret = Data("geheim".utf8)
        let a = try #require(FeedAuthCrypto.seal(secret, code: code))
        let b = try #require(FeedAuthCrypto.seal(secret, code: code))
        #expect(a != b, "frisches Salz je Schrieb, sonst verraet Wiederholung etwas")
        #expect(FeedAuthCrypto.open(a, code: code) == .plaintext(secret))
        #expect(FeedAuthCrypto.open(b, code: code) == .plaintext(secret))
    }

    @Test("ein veraenderter Umschlag oeffnet nicht")
    func atamperedEnvelopeDoesNotOpen() throws {
        let code = try #require(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB"))
        let sealed = try #require(FeedAuthCrypto.seal(Data("geheim".utf8), code: code))
        // Die werfenden Aufrufe stehen VOR dem Makro: ein `try` innerhalb
        // von `#require` laesst die Makro-Ausdehnung auf sich selbst laufen
        // und bricht den Bau, nicht den Fall.
        let parsed = try JSONSerialization.jsonObject(with: sealed)
        var document = try #require(parsed as? [String: Any])
        let bodyText = try #require(document["c"] as? String)
        let body = try #require(Data(base64Encoded: bodyText))
        var bytes = [UInt8](body)
        bytes[0] ^= 0xFF
        document["c"] = Data(bytes).base64EncodedString()
        let broken = try JSONSerialization.data(withJSONObject: document)
        #expect(FeedAuthCrypto.open(broken, code: code) == .sealedForAnother)
    }

    // MARK: - Die Zusammenfuehrung

    @Test("je Feed gewinnt der neuere Schrieb, und beide Seiten ueberleben")
    func theNewerWriteWinsAndBothSidesSurvive() {
        let local = ["a": entry("anna", "alt", at: 1000),
                     "nur-hier": entry("carl", "geheim", at: 500)]
        let remote = ["a": entry("anna", "neu", at: 2000),
                      "nur-dort": entry("dora", "geheim", at: 700)]
        let merged = FeedAuthMerge.union(local: local, remote: remote)
        #expect(merged["a"]?.credentials.password == "neu")
        #expect(merged["nur-hier"] != nil, "was nur hier liegt, bleibt")
        #expect(merged["nur-dort"] != nil, "was nur dort liegt, kommt an")
        #expect(merged.count == 3)
    }

    @Test("Gleichstand behaelt die lokale Seite, ohne Moment verliert man")
    func tiesKeepTheLocalSideAndNoMomentLoses() {
        let local = ["a": entry("anna", "hier", at: 1000),
                     "b": entry("bert", "hier", at: 0)]
        let remote = ["a": entry("anna", "dort", at: 1000),
                      "b": entry("bert", "dort", at: 1)]
        let merged = FeedAuthMerge.union(local: local, remote: remote)
        #expect(merged["a"]?.credentials.password == "hier")
        #expect(merged["b"]?.credentials.password == "dort")
    }

    @Test("eine Loeschung reist in diesem Format NICHT")
    func aRemovalDoesNotTravelInThisFormat() {
        // Die Gegenseite kennt den Feed nicht mehr. Er bleibt trotzdem,
        // und das ist die Entscheidung: ein bezahlter Zugang, den niemand
        // je gesehen hat, darf nicht durch eine Abwesenheit verschwinden.
        let local = ["bezahlt": entry("anna", "geheim", at: 1000)]
        let merged = FeedAuthMerge.union(local: local, remote: [:])
        #expect(merged["bezahlt"] != nil)
    }

    @Test("gleiche Zugaenge mit neuem Moment loesen KEINEN Schrieb aus")
    func are_stampAloneIsNoTraffic() {
        let local = ["a": entry("anna", "geheim", at: 1000)]
        let merged = ["a": entry("anna", "geheim", at: 9999)]
        #expect(!FeedAuthMerge.differs(merged, from: local))
        let changed = ["a": entry("anna", "anders", at: 9999)]
        #expect(FeedAuthMerge.differs(changed, from: local))
        #expect(FeedAuthMerge.differs(["a": entry("anna", "geheim", at: 1000),
                                       "b": entry("b", "c", at: 1)], from: local))
    }

    // MARK: - Die Regel, die einen bezahlten Feed schuetzt

    @Test("ein fremd versiegelter Block wird NICHT ueberschrieben")
    func aBlockSealedForAnotherIsNeverOverwritten() {
        // Der gefaehrliche Fall sieht harmlos aus: ein fremd versiegelter
        // Block ist voellig in Ordnung, er ist nur nicht unserer. Von hier
        // sieht er aus wie Schaden, und der Reflex auf Schaden ist ein
        // frischer Schrieb. Der wuerde jeden Zugang des anderen Geraets
        // loeschen.
        #expect(!FeedAuthStanding.mayWrite(.sealedForAnother))
        #expect(!FeedAuthStanding.mayWrite(.newerFormat(9)))
        #expect(FeedAuthStanding.mayWrite(.none), "die erste Einrichtung schreibt")
        #expect(FeedAuthStanding.mayWrite(.opens))
    }

    @Test("die Seite sagt dasselbe, was die Schreib-Erlaubnis sagt")
    func thePageAndThePermissionAreOneQuestion() {
        func standing(_ on: Bool, _ service: Bool,
                      _ block: FeedAuthStanding.Block) -> FeedAuthStanding.Standing {
            FeedAuthStanding.standing(syncAcrossDevices: on, hasService: service, block: block)
        }
        #expect(standing(false, true, .opens) == .switchedOff)
        #expect(standing(true, false, .none) == .noService)
        #expect(standing(true, true, .none) == .carrying)
        #expect(standing(true, true, .opens) == .carrying)
        #expect(standing(true, true, .sealedForAnother) == .needsCode)
        #expect(standing(true, true, .newerFormat(9)) == .newerBuild(9))
        // Und die Kopplung selbst: genau die Zustaende, die nicht schreiben
        // duerfen, sind die, die der Seite etwas zu sagen geben.
        for block: FeedAuthStanding.Block in [.none, .opens, .sealedForAnother, .newerFormat(9)] {
            #expect(FeedAuthStanding.mayWrite(block) == (standing(true, true, block) == .carrying),
                    "Seite und Erlaubnis laufen bei \(block) auseinander")
        }
    }

    @Test("eine nackte http-Adresse wird BENANNT und nicht gesperrt")
    func aPlainAddressIsNamedAndNotRefused() {
        // Gebaut fuer die Leute, die kein Zertifikat hinbekommen: eine
        // Sperre wuerde genau diese Zielgruppe aussperren. Also traegt es,
        // und der Mensch erfaehrt vorher, was die Adresse bedeutet.
        let carrying = FeedAuthStanding.standing(syncAcrossDevices: true, hasService: true,
                                                 block: .none)
        #expect(carrying == .carrying, "http aendert den Stand nicht")
        #expect(FeedAuthStanding.notice(addressIsSecure: false, standing: carrying) == .plainAddress)
        #expect(FeedAuthStanding.notice(addressIsSecure: true, standing: carrying) == nil)
        // Wo nichts reist, gibt es auch nichts zu warnen.
        #expect(FeedAuthStanding.notice(addressIsSecure: false, standing: .switchedOff) == nil)
        #expect(FeedAuthStanding.notice(addressIsSecure: false, standing: .noService) == nil)
        // Und die Erlaubnis zu schreiben haengt NICHT an der Adresse.
        #expect(FeedAuthStanding.mayWrite(.none))

        #expect(FeedAuthStanding.addressIsSecure("https://sync.maer.fm"))
        #expect(FeedAuthStanding.addressIsSecure("HTTPS://SYNC.MAER.FM"))
        #expect(!FeedAuthStanding.addressIsSecure("http://sync.maer.fm"))
        // Genau die zwei Adressformen, an denen die Plattform-Regel selbst
        // aufhoert: eine nackte Adresse und ein .local-Name.
        #expect(!FeedAuthStanding.addressIsSecure("http://192.168.178.5:8099"))
        #expect(!FeedAuthStanding.addressIsSecure("http://tiny.local:8099"))
    }

    // MARK: - Die Runde, und sie entscheidet alles Gefaehrliche

    private func plan(mine: [String: FeedAuthBlock.Entry] = [:],
                      theirs: [[String: FeedAuthBlock.Entry]] = [],
                      openings: [FeedAuthBlock.Opening] = []) -> FeedAuthRound.Plan {
        FeedAuthRound.plan(mine: mine, theirs: theirs, openings: openings)
    }

    @Test("das erste Geraet schreibt, ohne dass etwas da ist")
    func theFirstDeviceWrites() {
        let p = plan(mine: ["a": entry("anna", "geheim", at: 1000)])
        #expect(p.block == .none)
        #expect(p.putUp?.count == 1, "es geht hoch")
        #expect(p.apply == nil, "lokal aendert sich nichts")
    }

    @Test("oeffnet auch nur EIN fremder Block, gehoert der Code hierher")
    func oneOpeningBlockIsEnough() {
        let theirs = ["b": entry("bert", "geheim", at: 2000)]
        let p = plan(mine: ["a": entry("anna", "geheim", at: 1000)],
                     theirs: [theirs],
                     openings: [.plaintext(Data()), .sealedForAnother, .unreadable])
        #expect(p.block == .opens)
        #expect(p.putUp?.count == 2, "beide Seiten gehen hoch")
        #expect(p.apply?["b"] != nil, "was ankam, wird gehalten")
    }

    @Test("oeffnet KEINER, haelt das Geraet seinen eigenen Block zurueck")
    func nothingOpensMeansHoldBack() {
        // Der stille Schaden: zwei Haelften eines Kontos, die sich nie
        // lesen koennen, und beide sehen von innen gesund aus.
        let p = plan(mine: ["a": entry("anna", "geheim", at: 1000)],
                     openings: [.sealedForAnother, .sealedForAnother])
        #expect(p.block == .sealedForAnother)
        #expect(p.putUp == nil, "nichts geht hoch")
        #expect(p.apply == nil)
    }

    @Test("ein neueres Format haelt ebenfalls zurueck und wird benannt")
    func aNewerFormatHoldsBackToo() {
        let p = plan(openings: [.newerFormat(9), .sealedForAnother])
        #expect(p.block == .newerFormat(9))
        #expect(p.putUp == nil)
    }

    @Test("eine Runde, die nichts aendert, schreibt lokal nichts")
    func aRoundThatChangesNothingWritesNothing() {
        let same = ["a": entry("anna", "geheim", at: 1000)]
        let p = plan(mine: same, theirs: [same], openings: [.plaintext(Data())])
        #expect(p.apply == nil, "kein Schrieb in den Schluesselbund")
        #expect(p.putUp != nil, "hochgehen darf es trotzdem")
    }

    @Test("mehrere fremde Bloecke werden untereinander verschmolzen, nicht der letzte gewinnt")
    func severalForeignBlocksAreMergedAmongThemselves() {
        let one = ["a": entry("anna", "alt", at: 1000), "nur-eins": entry("x", "y", at: 5)]
        let two = ["a": entry("anna", "neu", at: 3000), "nur-zwei": entry("p", "q", at: 5)]
        let p = plan(mine: [:], theirs: [one, two],
                     openings: [.plaintext(Data()), .plaintext(Data())])
        #expect(p.apply?["a"]?.credentials.password == "neu")
        #expect(p.apply?["nur-eins"] != nil)
        #expect(p.apply?["nur-zwei"] != nil)
        #expect(p.apply?.count == 3)
    }
}
#endif
