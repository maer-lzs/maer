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
        #expect(FeedAuthCrypto.open(sealed, code: code, feed: nil) == .plaintext(secret))
    }

    @Test("ein fremder Schluessel oeffnet nicht, und der Umschlag sagt das")
    func aForeignKeyDoesNotOpen() throws {
        let mine = try #require(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB"))
        let theirs = try #require(DeviceLinkCode.normalized("ZYXW-VTSR-QPNM-KJHG-FEDC-BAZY"))
        let sealed = try #require(FeedAuthCrypto.seal(Data("geheim".utf8), code: mine))
        #expect(FeedAuthCrypto.open(sealed, code: theirs, feed: nil) == .sealedForAnother)
        // Kein Umschlag ist etwas anderes als ein fremder Umschlag.
        #expect(FeedAuthCrypto.open(Data("kein json".utf8), code: mine, feed: nil) == .unreadable)
    }

    @Test("zweimal dasselbe siegeln gibt zwei verschiedene Umschlaege")
    func sealingTwiceGivesTwoEnvelopes() throws {
        let code = try #require(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB"))
        let secret = Data("geheim".utf8)
        let a = try #require(FeedAuthCrypto.seal(secret, code: code))
        let b = try #require(FeedAuthCrypto.seal(secret, code: code))
        #expect(a != b, "frisches Salz je Schrieb, sonst verraet Wiederholung etwas")
        #expect(FeedAuthCrypto.open(a, code: code, feed: nil) == .plaintext(secret))
        #expect(FeedAuthCrypto.open(b, code: code, feed: nil) == .plaintext(secret))
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
        #expect(FeedAuthCrypto.open(broken, code: code, feed: nil) == .sealedForAnother)
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
                      openings: [FeedAuthBlock.Opening] = [],
                      listed: Bool = true) -> FeedAuthRound.Plan {
        FeedAuthRound.plan(mine: mine, theirs: theirs, openings: openings, listed: listed)
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

    @Test("vor der ersten Auflistung geht nichts hoch, auch wenn der Speicher leer aussieht")
    func nothingGoesUpBeforeTheFirstListing() {
        // Measured on 24.09.: signed in, the session's store empty, and the
        // block went up 4 ms later, before a single foreign one was seen.
        let mine = ["a": entry("anna", "geheim", at: 1000)]
        let before = plan(mine: mine, listed: false)
        #expect(before.putUp == nil, "nothing goes up before the far side was asked")
        #expect(before.hold == .notListedYet)
        let after = plan(mine: mine, listed: true)
        #expect(after.putUp?.count == 1 && after.hold == nil, "listed and empty: the first device writes")
    }

    @Test("jeder Grund zurueckzuhalten hat seine eigenen Worte, ein neueres Format ist kein fremder Code")
    func eachHoldNamesItsReason() {
        #expect(plan(openings: [.sealedForAnother]).hold == .sealedForAnother)
        #expect(plan(openings: [.newerFormat(9), .sealedForAnother]).hold == .newerFormat(9))
        #expect(plan(openings: [.plaintext(Data())]).hold == nil)
        #expect(FeedAuthRound.Hold.sealedForAnother.logReason == "the code is not this account's")
        #expect(FeedAuthRound.Hold.newerFormat(9).logReason == "a newer build wrote format 9")
        #expect(FeedAuthRound.Hold.notListedYet.logReason == "the other devices' blocks are not listed yet")
    }

    @Test("der Laeufer reicht die Auflistung weiter und schreibt den Grund aus dem Plan ins Log", .needsTheSources)
    func theRunnerWiresListingAndReason() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Networking/FeedAuthSync.swift"), encoding: .utf8)
        #expect(text.contains("listed: session.feedAuthListed)"))
        #expect(text.contains("let reason = plan.hold?.logReason"))
        #expect(!text.contains("holding back, the code is not this account's"), "no fixed reason in the line")
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

    @Test("der Preis der Vereinigung ist gemessen, nicht geschaetzt")
    func thePriceOfTheUnionIsMeasured() throws {
        // Hochgelegt wird die Vereinigung, also liegt sie einmal JE GERAET
        // auf dem Dienst. Damit diese Entscheidung nicht ungeschrieben neu
        // verhandelt wird, steht die Zahl hier und nicht in einer Schaetzung.
        let code = try #require(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB"))
        var entries: [String: FeedAuthBlock.Entry] = [:]
        for index in 0..<25 {
            // Ein Schluessel ist hoechstens 16 Zeichen (FNV-Hash der
            // normalisierten Adresse), Nutzer und Passwort realistisch lang.
            let key = String(format: "%016x", UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
            entries[key] = FeedAuthBlock.Entry(
                credentials: .init(user: "leser\(index)@example.invalid",
                                   password: "ein-ziemlich-langes-passwort-\(index)"),
                at: 1_700_000_000_000 + Double(index))
        }
        let plain = try #require(FeedAuthBlock.encode(entries))
        let sealed = try #require(FeedAuthCrypto.seal(plain, code: code))
        // Gemessen sind rund 3700 Byte. Die Schranke steht bei 8000, also
        // bei Faktor 2,16: der Fall faengt eine VERDOPPLUNG und ausdruecklich
        // nicht ein Wachstum um die Haelfte. Wer das aendert, soll wissen,
        // was er dabei aufgibt.
        #expect(sealed.count < 8_000, "versiegelt: \(sealed.count) Byte fuer 25 Feeds")
        #expect(sealed.count > plain.count, "der Umschlag kostet etwas")
        // Die Einordnung, die den Entscheid traegt, und sie ist die ENGERE
        // Schranke: zehn Geraete tragen die Vereinigung je einmal und
        // bleiben unter einem Promille der Koerper-Grenze des Dienstes.
        // Gegen die Grenze selbst zu pruefen waere eine Zusicherung, die bei
        // gehaltener erster Schranke gar nicht reissen KANN, also eine
        // Dokumentation im Gewand einer Messung.
        let tenDevices = sealed.count * 10
        #expect(tenDevices < 64 * 1024 * 1024 / 1000,
                "zehn Geraete: \(tenDevices) Byte, ein Promille waeren \(64 * 1024 * 1024 / 1000)")
    }

    // MARK: - Die Flaeche, und was sie NICHT selbst entscheidet

    @MainActor
    private func settingsPage() throws -> String {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "MaerSyncSettingsView.swift" })
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("die Seite fragt die Regel, statt selbst zu entscheiden", .needsTheSources)
    func thePageAsksTheRule() throws {
        let text = try settingsPage()
        #expect(text.contains("FeedAuthStanding.standing("), "die Seite baut den Stand selbst")
        #expect(text.contains("FeedAuthStanding.notice("), "die Seite entscheidet den Hinweis selbst")
    }

    @Test("die Seite zeigt keinen Code mehr, und der Preis steht als Tatsache vorher", .needsTheSources)
    func thePageShowsNoCodeAndThePriceComesFirst() throws {
        let text = try settingsPage()
        // Der Code ist abgeschafft: nichts zu kopieren, nichts zu tippen,
        // nichts zu erzeugen.
        #expect(!text.contains("UIPasteboard"), "ein Kopier-Weg fuer einen Code steht noch da")
        #expect(!text.contains("DeviceLinkCode"), "die Seite fasst den Code noch an")
        #expect(!text.contains("feed-auth-code"), "eine Code-Flaeche traegt noch ihre Kennung")
        // Der Preis steht in der Fusszeile, also VORHER sichtbar, und als
        // Tatsache, nicht als Verhalten.
        #expect(text.contains("travel sealed with a key that comes from your account password, which the service never sees."))
        #expect(text.contains("If the password is forgotten and no device holds the credentials any more, they are gone."))
    }

    /// Reads the page with comment lines cut and whitespace pulled together.
    private func settingsCode() throws -> String {
        try settingsPage().split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }

    @Test("nach der Anmeldung startet der Laeufer mit dem Feed-Schluessel, ein Code entsteht nirgends", .needsTheSources)
    func theRunnerFollowsTheSignIn() throws {
        let code = try settingsCode()
        // The sign-in reaches the runner through the one place that writes
        // the access; the runner is enrolled there like the five others.
        let signedIn = try #require(code.range(of: "case.signedIn(letaccess,letaccount):"))
        #expect(code[signedIn.upperBound...].prefix(400).contains("MaerSyncSignIn.store(access,owner:account)"))
        #expect(AccessFollowers.names.contains(FeedAuthSync.shared.followerName), "the feed access runner does not follow the sign-in")
        #expect(!code.contains("ensure()") && !code.contains("adopt(typed:"), "a code still comes into being")
    }

    @Test("der Block wird beobachtet, nicht gespiegelt", .needsTheSources)
    func theBlockIsObservedNotMirrored() throws {
        let code = try settingsCode()
        #expect(code.contains("@ObservedObjectprivatevarfeedAuth=FeedAuthSync.shared"), "the page does not observe the runner")
        #expect(!code.contains("@StateprivatevarfeedAuthBlock"), "the page still mirrors the block")
        #expect(code.contains("block:feedAuth.block)"), "the standing does not read the runner's block")
        let runner = try #require(ProjectFileIntegrityTests.sourceFiles().first { $0.lastPathComponent == "FeedAuthSync.swift" })
        let text = try String(contentsOf: runner, encoding: .utf8)
        #expect(text.contains("final class FeedAuthSync: ObservableObject"))
        #expect(text.contains("@Published private(set) var block"))
    }

    @Test("der Schluesselwechsel gehoert zu seiner Adresse und faellt mit ihr", .needsTheSources)
    func theKeyChangeBelongsToItsAddress() throws {
        let change = MaerSyncSettingsView.KeyChange(held: "AAAA", offered: "BBBB", address: "https://one.example")
        #expect(change.stands(forAddress: "https://one.example"))
        #expect(!change.stands(forAddress: "https://two.example"))
        let code = try settingsCode()
        let onChange = try #require(code.range(of: ".onChange(of:serverURL){_,addressin"))
        let body = code[onChange.upperBound...].prefix(200)
        #expect(body.contains("!keyChange.stands(forAddress:address){self.keyChange=nil}"),
                "typing another address leaves the old address's key change standing")
        #expect(code.contains("KeyChange(held:change.held,offered:change.offered,address:serverURL)"))
        #expect(code.contains("KeyChange(held:held,offered:offered,address:serverURL)"))
    }

    /// The page reads the session again after every change it makes,
    /// through ONE helper.
    @Test("die Seite liest die Sitzung nach jeder eigenen Aenderung neu", .needsTheSources)
    func thePageReadsTheSessionAgainAfterItsOwnChanges() throws {
        let code = try settingsCode()
        let helper = try #require(code.range(of: "privatefuncrefreshFromSession(){"))
        let body = code[helper.upperBound...].prefix(260)
        #expect(body.contains("refusal=MaerSyncCarriers.session.lastRefusal"))
        #expect(body.contains("tokenRefused=MaerSyncCarriers.session.unauthorized"))
        let appear = try #require(code.range(of: ".onAppear{"))
        #expect(code[appear.upperBound...].prefix(40).contains("refreshFromSession()"), "the appearance does not read the session")
        let signedIn = try #require(code.range(of: "case.signedIn(letaccess,letaccount):"))
        #expect(code[signedIn.upperBound...].prefix(400).contains("refreshFromSession()"), "signing in does not read the session again")
        let signOut = try #require(code.range(of: "privatefuncsignOut(){"))
        #expect(code[signOut.upperBound...].prefix(200).contains("refreshFromSession()"), "signing out does not read the session again")
    }

    @Test("waehrend ein neues Passwort gesetzt wird, steht das geltende zuerst im Abschnitt und oben nicht, ein Feld fuer einen Wert", .needsTheSources)
    func thePasswordInForceMovesIntoTheSection() throws {
        let code = try settingsCode()
        #expect(code.contains("if!settingNewPassword{CredentialField.secret(\"Password\",text:$secret,id:\"maer-sync-password\")}"),
                "the field at the top stays while the section is open")
        let section = try #require(code.range(of: "privatevarnewPasswordSection:someView{Section{"))
        #expect(code[section.upperBound...].hasPrefix(
            "CredentialField.secret(\"Passwordinforce\",text:$secret,id:\"maer-sync-password\")CredentialField.secret(\"Newpassword\""),
                "the password in force does not come first in the section")
        #expect(code.components(separatedBy: "text:$secret").count - 1 == 2, "one value, one field that moves")
    }

    @Test("Bei grosser Schrift steht der Titel eines Zugangsfelds ueber ihm, statt als Platzhalter geschrumpft zu werden, an allen drei Feldern", .needsTheSources)
    func credentialTitlesStandAboveAtLargeText() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "CredentialFields.swift" })
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.components(separatedBy: "TitledCredential(title: title) { large in").count - 1 == 3,
                "server, account and secret each go through the one wrapper")
        #expect(text.components(separatedBy: "if large {").count - 1 == 3)
        #expect(text.components(separatedBy: "prompt: Text(verbatim: \"\")) { Text(title) }").count - 1 == 3,
                "the large field keeps its title as its label and shows no placeholder")
        let wrapper = try #require(functionBody(of: "private struct TitledCredential<Field: View>: View {", in: text))
        let large = try #require(wrapper.range(of: "if typeSize.isAccessibilitySize {"))
        #expect(wrapper[large.upperBound...].prefix(300).contains("field(true)"))
    }

    @Test("Geaenderte Zugangsdaten eines bekannten Feeds sind ein Eintreffen wie neue, gleiche nicht", .needsTheSources)
    func changedCredentialsArriveLikeNewOnes() throws {
        let mine = ["a": entry("u", "alt", at: 1)]
        #expect(FeedAuthRound.accessArrived(apply: ["a": entry("u", "neu", at: 2)], mine: mine), "a changed password")
        #expect(FeedAuthRound.accessArrived(apply: ["a": entry("u", "alt", at: 1), "b": entry("v", "p", at: 2)], mine: mine),
                "a new feed")
        #expect(!FeedAuthRound.accessArrived(apply: ["a": entry("u", "alt", at: 5)], mine: mine),
                "only the moment moved: the same sign-in")
        #expect(!FeedAuthRound.accessArrived(apply: [:], mine: mine), "nothing applied")
        // Wiring: the round asks the rule, the old key-only question is gone.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Networking/FeedAuthSync.swift"),
                              encoding: .utf8)
        #expect(text.contains("if FeedAuthRound.accessArrived(apply: apply, mine: mine) {"))
        #expect(!text.contains("subtracting(mine.keys)"))
    }
}
#endif
