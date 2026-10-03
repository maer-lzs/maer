// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The quiet ways: an older service is named and stops the rounds, and
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

    // MARK: - An older service

    @Test("aelterer Dienst: 404 am Schluessel oder Handschlag und 426 auf jedem Datenweg heissen beim Namen")
    func anOlderServiceIsNamedWhereTheNumberIsRead() {
        #expect(failure { _ = try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 404)) } == .serviceIsOlder)
        #expect(failure { _ = try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 426)) } == .serviceIsOlder,
                "G20-1: what Dienst 5 measurably answered on the key")
        #expect(failure { _ = try MaerSyncAnswer.session(MaerSyncReply(status: 404)) } == .serviceIsOlder)
        #expect(failure { _ = try MaerSyncAnswer.tunnel(MaerSyncReply(status: 404)) } == .serviceIsOlder)
        #expect(failure { _ = try MaerSyncAnswer.tunnel(MaerSyncReply(status: 426)) } == .serviceIsOlder)
        #expect(failure { _ = try MaerSyncAnswer.document(MaerSyncReply(status: 426)) } == .serviceIsOlder)
        #expect(failure { _ = try MaerSyncAnswer.written(MaerSyncReply(status: 426)) } == .serviceIsOlder)
        #expect(failure { _ = try MaerSyncAnswer.listing(MaerSyncReply(status: 426)) } == .serviceIsOlder)
        // What stays as it was: a missing document is "not there yet".
        #expect(failure { _ = try MaerSyncAnswer.document(MaerSyncReply(status: 404)) } == nil)
    }

    @Test("aelterer Dienst, der gemessene Fall vom 24.09.: 426 auf /v2/key durch die echte Tuer haelt die Laeufe an")
    @MainActor
    func theMeasuredCaseStops() async throws {
        // The contract-5 service answered 426 on /v2/key, measured at its code. Every request of
        // this door meets exactly that, as the device did.
        let paths = PathLog()
        let wire: MaerSyncWire = { request in
            await paths.note(request.url?.path ?? "")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 426, httpVersion: nil, headerFields: nil))
        }
        let door = MaerSyncHTTP(tunnels: MaerSyncTunnels(wire: wire), wire: wire)
        let name = "quiet-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let base = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
        let announcer = MaerSyncCarrierTests.FakeAnnouncer()
        let session = MaerSyncSession(transport: door, announcer: announcer,
                                      access: { MaerSyncAccess(baseURL: base, token: "a-token") },
                                      deviceId: { "dev-a" }, defaults: defaults)
        await session.refresh(by: "scene active")
        #expect(session.serviceOlder, "the first 426 on the key stops the rounds")
        let asked = await paths.count
        #expect(await paths.all.allSatisfy { $0 == "/v2/key" }, "nothing but the key path was asked")
        await session.refresh(by: "start")
        await session.refresh(by: "housekeeping")
        #expect(await paths.count == asked, "no occasion asks again, as the device did every time")
        // Coming back asks ONCE more, and stops again on the same answer.
        session.askAgainOnReturn()
        await session.refresh(by: "scene active")
        #expect(await paths.count > asked)
        #expect(session.serviceOlder)
    }

    /// The paths a door asked, in order.
    actor PathLog {
        private(set) var all: [String] = []
        var count: Int { all.count }
        func note(_ path: String) { all.append(path) }
    }

    @Test("aelterer Dienst: die Rueckkehr in den Vordergrund fragt genau einmal neu, sonst nichts")
    func theReturnAsksOnce() throws {
        let housekeeping = try Self.source("Sources/ViewModels/AppHousekeeping.swift")
        let ask = try #require(housekeeping.range(of: "MaerSyncCarriers.session.askAgainOnReturn()"))
        let refresh = try #require(housekeeping.range(of: "Task { await CarrierRefreshers.refreshAll(by: \"scene active\") }"))
        #expect(ask.lowerBound < refresh.lowerBound, "cleared before the refresh of the same return")
        let session = try Self.source("Sources/Networking/MaerSyncCarriers.swift")
        #expect(session.contains("func askAgainOnReturn() { guard serviceOlder else { return } serviceOlder = false"))
    }

    @Test("aelterer Dienst: die Seite sagt es, vor dem Token und nach dem Schalter")
    func thePageSaysIt() {
        #expect(MaerSyncStanding.standing(syncAcrossDevices: true, signedIn: true,
                                          tokenRefused: true, serviceOlder: true) == .serviceOlder)
        #expect(MaerSyncStanding.standing(syncAcrossDevices: false, signedIn: true,
                                          serviceOlder: true) == .switchedOff)
    }

    @Test("aelterer Dienst: die Anmeldung nennt ihn auch auf dem Weg ueber Salz und Token")
    func theSignInNamesItOnEveryStep() {
        for step in [MaerSyncSignIn.Step.signInSalt, .signInToken, .changeSalt, .change] {
            #expect(MaerSyncSignIn.outcome(forSignInError: MaerSyncFailure.serviceIsOlder, host: "h", step: step) == .serviceIsOlder)
        }
    }

    // MARK: - Every refusal says itself

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
