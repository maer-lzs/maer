// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// P6, the quiet ways: an older service is named and stops the rounds, and
/// every failure of a sign-in or a password change says itself in the log.
struct QuietWaysTests {
    private static func squeezed(_ raw: String) -> String {
        SyncContractFenceTests.stripped(raw)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return squeezed(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8))
    }

    private func failure(_ body: () throws -> Void) -> MaerSyncFailure? {
        do { try body(); return nil } catch { return error as? MaerSyncFailure }
    }

    // MARK: - GT-20: an older service

    @Test("aelterer Dienst: 404 am Schluessel oder Handschlag und 426 auf jedem Datenweg heissen beim Namen")
    func anOlderServiceIsNamedWhereTheNumberIsRead() {
        #expect(failure { _ = try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 404)) } == .serviceIsOlder)
        #expect(failure { _ = try MaerSyncAnswer.session(MaerSyncReply(status: 404)) } == .serviceIsOlder)
        #expect(failure { _ = try MaerSyncAnswer.tunnel(MaerSyncReply(status: 404)) } == .serviceIsOlder)
        #expect(failure { _ = try MaerSyncAnswer.tunnel(MaerSyncReply(status: 426)) } == .serviceIsOlder)
        #expect(failure { _ = try MaerSyncAnswer.document(MaerSyncReply(status: 426)) } == .serviceIsOlder)
        #expect(failure { _ = try MaerSyncAnswer.written(MaerSyncReply(status: 426)) } == .serviceIsOlder)
        #expect(failure { _ = try MaerSyncAnswer.listing(MaerSyncReply(status: 426)) } == .serviceIsOlder)
        // What stays as it was: a missing document is "not there yet".
        #expect(failure { _ = try MaerSyncAnswer.document(MaerSyncReply(status: 404)) } == nil)
    }

    @Test("aelterer Dienst: die Seite sagt es, vor dem Token und nach dem Schalter, und nichts reist")
    func thePageSaysIt() {
        #expect(MaerSyncStanding.standing(syncAcrossDevices: true, carrierIsTheService: true, signedIn: true,
                                          tokenRefused: true, serviceOlder: true) == .serviceOlder)
        #expect(MaerSyncStanding.standing(syncAcrossDevices: false, carrierIsTheService: true, signedIn: true,
                                          serviceOlder: true) == .switchedOff)
        #expect(!MaerSyncStanding.serviceOlder.somethingTravels)
    }

    @Test("aelterer Dienst: die Anmeldung nennt ihn auch auf dem Weg ueber Salz und Token")
    func theSignInNamesItOnEveryStep() {
        for step in [MaerSyncSignIn.Step.signInSalt, .signInToken, .changeSalt, .change] {
            #expect(MaerSyncSignIn.outcome(forSignInError: MaerSyncFailure.serviceIsOlder, host: "h", step: step) == .serviceIsOlder)
        }
    }

    // MARK: - GT-22: every refusal says itself

    @Test("Abweisung: 401, 428 und 429 an Anmeldung und Wechsel fuehren zu ihrem Satz")
    func refusalsKeepTheirOutcome() {
        #expect(MaerSyncSignIn.outcome(forSignInError: MaerSyncFailure.unauthorized, host: nil, step: .change) == .refused)
        #expect(MaerSyncSignIn.outcome(forSignInError: MaerSyncFailure.passwordChanged, host: nil, step: .signInToken) == .refused)
        #expect(MaerSyncSignIn.outcome(forSignInError: MaerSyncFailure.operatorSetPassword, host: nil, step: .signInToken) == .needsNewPassword)
        #expect(MaerSyncSignIn.outcome(forSignInError: MaerSyncFailure.tooManyAttempts(retryAfter: 30), host: nil, step: .change)
                == .tooManyAttempts(retryAfter: 30))
    }

    @Test("Abweisung: jeder Ausgang schreibt zuerst seine Logzeile mit Schritt, und jeder Weg nennt seinen Schritt")
    func everyFailureWritesItsLine() throws {
        let signIn = try Self.source("Sources/Networking/MaerSyncSignIn.swift")
        let head = try #require(signIn.range(of: "nonisolated static func outcome(forSignInError error: Error, host: String?, step: Step) -> Outcome {"))
        let body = signIn[head.upperBound...]
        let log = try #require(body.range(of: "Logger.library.notice(\"MAERSYNC \\(step.rawValue, privacy: .public) failed host="))
        let decide = try #require(body.range(of: "switch error as? MaerSyncFailure {"))
        #expect(log.lowerBound < decide.lowerBound, "the line comes before any case can return")
        for step in [".signInSalt", ".signInToken", ".changeSalt", ".change)"] {
            #expect(signIn.contains("host: base.host, step: \(step)"), "\(step) is named at its way")
        }
        #expect(!signIn.contains("outcome(forSignInError: error, host: base.host)"), "no way without its step")
    }
}
#endif
