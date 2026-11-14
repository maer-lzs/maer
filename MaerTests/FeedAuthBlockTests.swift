// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The block of feed accesses: its writing, its seal, its
/// merge and the one rule that protects a paid feed.
struct FeedAuthBlockTests {
    private func entry(_ user: String, _ password: String, at: Double) -> FeedAuthBlock.Entry {
        FeedAuthBlock.Entry(credentials: .init(user: user, password: password), at: at)
    }

    // MARK: - The writing

    @Test("Round trip, and equal entries give equal bytes")
    func roundTripIsStable() throws {
        let entries = ["feed-a": entry("anna", "geheim", at: 1000),
                       "feed-b": entry("bert", "auch geheim", at: 2000)]
        let data = try #require(FeedAuthBlock.encode(entries))
        guard case .entries(let back) = FeedAuthBlock.decode(data) else {
            Issue.record("nicht lesbar"); return
        }
        #expect(back == entries)
        // Written sorted: the same state gives the same bytes, so
        // a difference really means a change and not a
        // different dictionary order.
        #expect(FeedAuthBlock.encode(entries) == data)
    }

    @Test("a newer format is reported as such, not as junk")
    func aNewerFormatIsNamed() throws {
        let document: [String: Any] = ["v": FeedAuthBlock.format + 5, "e": [:]]
        let data = try JSONSerialization.data(withJSONObject: document)
        #expect(FeedAuthBlock.decode(data) == .newerFormat(FeedAuthBlock.format + 5))
    }

    @Test("Unreadable is not empty")
    func unreadableIsNotEmpty() {
        #expect(FeedAuthBlock.decode(Data("kein json".utf8)) == .unreadable)
        #expect(FeedAuthBlock.decode(Data()) == .unreadable)
        // A block WITHOUT an entries field is broken, not empty.
        let noEntries = try? JSONSerialization.data(withJSONObject: ["v": 1])
        #expect(FeedAuthBlock.decode(noEntries ?? Data()) == .unreadable)
        // But an empty entries field is really empty.
        let empty = try? JSONSerialization.data(withJSONObject: ["v": 1, "e": [:]])
        #expect(FeedAuthBlock.decode(empty ?? Data()) == .entries([:]))
    }

    @Test("a half entry is skipped, a missing moment is not")
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

    // MARK: - The seal

    @Test("the service carries what it cannot read")
    func theServiceCarriesWhatItCannotRead() throws {
        let code = try #require(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB"))
        let secret = Data("anna\ngeheim".utf8)
        let sealed = try #require(FeedAuthCrypto.seal(secret, code: code))
        // The secret stands nowhere in the envelope.
        let text = String(data: sealed, encoding: .utf8) ?? ""
        #expect(!text.contains("geheim"))
        #expect(!text.contains("anna"))
        // And the envelope is JSON, because the service's gate accepts only readable
        // documents.
        #expect((try? JSONSerialization.jsonObject(with: sealed)) != nil)
        #expect(FeedAuthCrypto.open(sealed, code: code, feed: nil) == .plaintext(secret))
    }

    @Test("a foreign key does not open, and the envelope says so")
    func aForeignKeyDoesNotOpen() throws {
        let mine = try #require(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB"))
        let theirs = try #require(DeviceLinkCode.normalized("ZYXW-VTSR-QPNM-KJHG-FEDC-BAZY"))
        let sealed = try #require(FeedAuthCrypto.seal(Data("geheim".utf8), code: mine))
        #expect(FeedAuthCrypto.open(sealed, code: theirs, feed: nil) == .sealedForAnother)
        // No envelope is something other than a foreign envelope.
        #expect(FeedAuthCrypto.open(Data("kein json".utf8), code: mine, feed: nil) == .unreadable)
    }

    @Test("sealing the same thing twice gives two different envelopes")
    func sealingTwiceGivesTwoEnvelopes() throws {
        let code = try #require(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB"))
        let secret = Data("geheim".utf8)
        let a = try #require(FeedAuthCrypto.seal(secret, code: code))
        let b = try #require(FeedAuthCrypto.seal(secret, code: code))
        #expect(a != b, "frisches Salz je Schrieb, sonst verraet Wiederholung etwas")
        #expect(FeedAuthCrypto.open(a, code: code, feed: nil) == .plaintext(secret))
        #expect(FeedAuthCrypto.open(b, code: code, feed: nil) == .plaintext(secret))
    }

    @Test("an altered envelope does not open")
    func atamperedEnvelopeDoesNotOpen() throws {
        let code = try #require(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB"))
        let sealed = try #require(FeedAuthCrypto.seal(Data("geheim".utf8), code: code))
        // The throwing calls stand BEFORE the macro: a `try` inside
        // `#require` makes the macro expansion run on itself
        // and breaks the build, not the case.
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

    // MARK: - The merge

    @Test("per feed the newer write wins, and both sides survive")
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

    @Test("A tie keeps the local side, without a moment one loses")
    func tiesKeepTheLocalSideAndNoMomentLoses() {
        let local = ["a": entry("anna", "hier", at: 1000),
                     "b": entry("bert", "hier", at: 0)]
        let remote = ["a": entry("anna", "dort", at: 1000),
                      "b": entry("bert", "dort", at: 1)]
        let merged = FeedAuthMerge.union(local: local, remote: remote)
        #expect(merged["a"]?.credentials.password == "hier")
        #expect(merged["b"]?.credentials.password == "dort")
    }

    @Test("a deletion does NOT travel in this format")
    func aRemovalDoesNotTravelInThisFormat() {
        // The other side no longer knows the feed. It stays anyway,
        // and that is the decision: a paid access that nobody
        // has ever seen must not disappear through an absence.
        let local = ["bezahlt": entry("anna", "geheim", at: 1000)]
        let merged = FeedAuthMerge.union(local: local, remote: [:])
        #expect(merged["bezahlt"] != nil)
    }

    @Test("equal accesses with a new moment trigger NO write")
    func are_stampAloneIsNoTraffic() {
        let local = ["a": entry("anna", "geheim", at: 1000)]
        let merged = ["a": entry("anna", "geheim", at: 9999)]
        #expect(!FeedAuthMerge.differs(merged, from: local))
        let changed = ["a": entry("anna", "anders", at: 9999)]
        #expect(FeedAuthMerge.differs(changed, from: local))
        #expect(FeedAuthMerge.differs(["a": entry("anna", "geheim", at: 1000),
                                       "b": entry("b", "c", at: 1)], from: local))
    }

    // MARK: - The rule that protects a paid feed

    @Test("a block sealed by a foreign party is NOT overwritten")
    func aBlockSealedForAnotherIsNeverOverwritten() {
        // The dangerous case looks harmless: a block sealed by a foreign party
        // is perfectly fine, it is just not ours. From here
        // it looks like damage, and the reflex on damage is a
        // fresh write. That would delete every access of the other
        // device.
        #expect(!FeedAuthStanding.mayWrite(.sealedForAnother))
        #expect(!FeedAuthStanding.mayWrite(.newerFormat(9)))
        #expect(FeedAuthStanding.mayWrite(.none), "die erste Einrichtung schreibt")
        #expect(FeedAuthStanding.mayWrite(.opens))
    }

    @Test("the page says the same as the write permission says")
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
        // And the coupling itself: exactly the states that may not write
        // are the ones that give the page something to say.
        for block: FeedAuthStanding.Block in [.none, .opens, .sealedForAnother, .newerFormat(9)] {
            #expect(FeedAuthStanding.mayWrite(block) == (standing(true, true, block) == .carrying),
                    "Seite und Erlaubnis laufen bei \(block) auseinander")
        }
    }

    @Test("a bare http address is NAMED and not blocked")
    func aPlainAddressIsNamedAndNotRefused() {
        // Built for the people who cannot get a certificate: a
        // block would lock out exactly this target group. So it carries,
        // and the person learns beforehand what the address means.
        let carrying = FeedAuthStanding.standing(syncAcrossDevices: true, hasService: true,
                                                 block: .none)
        #expect(carrying == .carrying, "http aendert den Stand nicht")
        #expect(FeedAuthStanding.notice(addressIsSecure: false, standing: carrying) == .plainAddress)
        #expect(FeedAuthStanding.notice(addressIsSecure: true, standing: carrying) == nil)
        // Where nothing travels, there is nothing to warn about either.
        #expect(FeedAuthStanding.notice(addressIsSecure: false, standing: .switchedOff) == nil)
        #expect(FeedAuthStanding.notice(addressIsSecure: false, standing: .noService) == nil)
        // And the permission to write does NOT depend on the address.
        #expect(FeedAuthStanding.mayWrite(.none))

        #expect(FeedAuthStanding.addressIsSecure("https://sync.maer.fm"))
        #expect(FeedAuthStanding.addressIsSecure("HTTPS://SYNC.MAER.FM"))
        #expect(!FeedAuthStanding.addressIsSecure("http://sync.maer.fm"))
        // Exactly the two address forms where the platform rule itself
        // stops: a bare address and a .local name.
        #expect(!FeedAuthStanding.addressIsSecure("http://192.168.178.5:8099"))
        #expect(!FeedAuthStanding.addressIsSecure("http://tiny.local:8099"))
    }

    // MARK: - The round, and it decides everything dangerous

    private func plan(mine: [String: FeedAuthBlock.Entry] = [:],
                      theirs: [[String: FeedAuthBlock.Entry]] = [],
                      openings: [FeedAuthBlock.Opening] = [],
                      listed: Bool = true) -> FeedAuthRound.Plan {
        FeedAuthRound.plan(mine: mine, theirs: theirs, openings: openings, listed: listed)
    }

    @Test("the first device writes, without anything being there")
    func theFirstDeviceWrites() {
        let p = plan(mine: ["a": entry("anna", "geheim", at: 1000)])
        #expect(p.block == .none)
        #expect(p.putUp?.count == 1, "es geht hoch")
        #expect(p.apply == nil, "lokal aendert sich nichts")
    }

    @Test("if even ONE foreign block opens, the code belongs here")
    func oneOpeningBlockIsEnough() {
        let theirs = ["b": entry("bert", "geheim", at: 2000)]
        let p = plan(mine: ["a": entry("anna", "geheim", at: 1000)],
                     theirs: [theirs],
                     openings: [.plaintext(Data()), .sealedForAnother, .unreadable])
        #expect(p.block == .opens)
        #expect(p.putUp?.count == 2, "beide Seiten gehen hoch")
        #expect(p.apply?["b"] != nil, "was ankam, wird gehalten")
    }

    @Test("if NONE opens, the device holds back its own block")
    func nothingOpensMeansHoldBack() {
        // The silent damage: two halves of an account that can never
        // read each other, and both look healthy from the inside.
        let p = plan(mine: ["a": entry("anna", "geheim", at: 1000)],
                     openings: [.sealedForAnother, .sealedForAnother])
        #expect(p.block == .sealedForAnother)
        #expect(p.putUp == nil, "nichts geht hoch")
        #expect(p.apply == nil)
    }

    @Test("a newer format also holds back and is named")
    func aNewerFormatHoldsBackToo() {
        let p = plan(openings: [.newerFormat(9), .sealedForAnother])
        #expect(p.block == .newerFormat(9))
        #expect(p.putUp == nil)
    }

    @Test("before the first listing nothing goes up, even if the store looks empty")
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

    @Test("every reason to hold back has its own words, a newer format is no foreign code")
    func eachHoldNamesItsReason() {
        #expect(plan(openings: [.sealedForAnother]).hold == .sealedForAnother)
        #expect(plan(openings: [.newerFormat(9), .sealedForAnother]).hold == .newerFormat(9))
        #expect(plan(openings: [.plaintext(Data())]).hold == nil)
        #expect(FeedAuthRound.Hold.sealedForAnother.logReason == "the code is not this account's")
        #expect(FeedAuthRound.Hold.newerFormat(9).logReason == "a newer build wrote format 9")
        #expect(FeedAuthRound.Hold.notListedYet.logReason == "the other devices' blocks are not listed yet")
    }

    @Test("the runner passes the listing on and writes the reason from the plan into the log", .needsTheSources)
    func theRunnerWiresListingAndReason() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Networking/FeedAuthSync.swift"), encoding: .utf8)
        #expect(text.contains("listed: session.feedAuthListed)"))
        #expect(text.contains("let reason = plan.hold?.logReason"))
        #expect(!text.contains("holding back, the code is not this account's"), "no fixed reason in the line")
    }

    @Test("a round that changes nothing writes nothing locally")
    func aRoundThatChangesNothingWritesNothing() {
        let same = ["a": entry("anna", "geheim", at: 1000)]
        let p = plan(mine: same, theirs: [same], openings: [.plaintext(Data())])
        #expect(p.apply == nil, "kein Schrieb in den Schluesselbund")
        #expect(p.putUp != nil, "hochgehen darf es trotzdem")
    }

    @Test("several foreign blocks are merged with each other, the last does not simply win")
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

    @Test("the price of the union is measured, not estimated")
    func thePriceOfTheUnionIsMeasured() throws {
        // The union is what gets uploaded, so it lies once PER DEVICE
        // on the service. So that this decision is not renegotiated
        // unwritten, the number stands here and not in an estimate.
        let code = try #require(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB"))
        var entries: [String: FeedAuthBlock.Entry] = [:]
        for index in 0..<25 {
            // A key is at most 16 characters (FNV hash of the
            // normalized address), user and password realistically long.
            let key = String(format: "%016x", UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
            entries[key] = FeedAuthBlock.Entry(
                credentials: .init(user: "leser\(index)@example.invalid",
                                   password: "ein-ziemlich-langes-passwort-\(index)"),
                at: 1_700_000_000_000 + Double(index))
        }
        let plain = try #require(FeedAuthBlock.encode(entries))
        let sealed = try #require(FeedAuthCrypto.seal(plain, code: code))
        // Measured are about 3700 bytes. The bound stands at 8000, so
        // at a factor of 2.16: the case catches a DOUBLING and explicitly
        // not a growth by half. Whoever changes that should know
        // what they give up.
        #expect(sealed.count < 8_000, "versiegelt: \(sealed.count) Byte fuer 25 Feeds")
        #expect(sealed.count > plain.count, "der Umschlag kostet etwas")
        // The classification that carries the decision, and it is the NARROWER
        // bound: ten devices carry the union once each and
        // stay below a thousandth of the service's body limit.
        // Checking against the limit itself would be an assertion that, with
        // the first bound held, CANNOT fail at all, so a
        // documentation in the guise of a measurement.
        let tenDevices = sealed.count * 10
        #expect(tenDevices < 64 * 1024 * 1024 / 1000,
                "zehn Geraete: \(tenDevices) Byte, ein Promille waeren \(64 * 1024 * 1024 / 1000)")
    }

    // MARK: - The surface, and what it does NOT decide itself

    @MainActor
    private func settingsPage() throws -> String {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "MaerSyncSettingsView.swift" })
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("the page asks the rule instead of deciding itself", .needsTheSources)
    func thePageAsksTheRule() throws {
        let text = try settingsPage()
        #expect(text.contains("FeedAuthStanding.standing("), "die Seite baut den Stand selbst")
        #expect(text.contains("FeedAuthStanding.notice("), "die Seite entscheidet den Hinweis selbst")
    }

    @Test("the page shows no code any more, and the price stands as a fact beforehand", .needsTheSources)
    func thePageShowsNoCodeAndThePriceComesFirst() throws {
        let text = try settingsPage()
        // The code is abolished: nothing to copy, nothing to type,
        // nothing to generate.
        #expect(!text.contains("UIPasteboard"), "ein Kopier-Weg fuer einen Code steht noch da")
        #expect(!text.contains("DeviceLinkCode"), "die Seite fasst den Code noch an")
        #expect(!text.contains("feed-auth-code"), "eine Code-Flaeche traegt noch ihre Kennung")
        // The price stands in the footer, so visible BEFOREHAND, and as a
        // fact, not as behavior.
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

    @Test("after the sign-in the runner starts with the feed key, no code is generated anywhere", .needsTheSources)
    func theRunnerFollowsTheSignIn() throws {
        let code = try settingsCode()
        // The sign-in reaches the runner through the one place that writes
        // the access; the runner is enrolled there like the five others.
        let signedIn = try #require(code.range(of: "case.signedIn(letaccess,letaccount):"))
        #expect(code[signedIn.upperBound...].prefix(400).contains("MaerSyncSignIn.store(access,owner:account)"))
        #expect(AccessFollowers.names.contains(FeedAuthSync.shared.followerName), "the feed access runner does not follow the sign-in")
        #expect(!code.contains("ensure()") && !code.contains("adopt(typed:"), "a code still comes into being")
    }

    @Test("the block is observed, not mirrored", .needsTheSources)
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

    @Test("the key change belongs to its address and falls with it", .needsTheSources)
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
    @Test("the page reads the session again after every change of its own", .needsTheSources)
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

    @Test("while a new password is being set, the current one stands first in the section and not at the top, one field for one value", .needsTheSources)
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

    @Test("At large type the title of an access field stands above it, instead of being shrunk as a placeholder, at all three fields", .needsTheSources)
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

    @Test("Changed credentials of a known feed count as an arrival like new ones, equal ones do not", .needsTheSources)
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
