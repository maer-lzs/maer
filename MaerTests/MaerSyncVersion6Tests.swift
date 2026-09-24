// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import CryptoKit
@testable import Maer

/// The sign-in of contract version 6 on the wire: the answers, the flow,
/// the cases of `faelle-v6.json` replayed through the real door, and the
/// fence that no way back to the old sign-in exists.
struct MaerSyncVersion6Tests {
    private func failure(_ body: () throws -> Void) -> MaerSyncFailure? {
        do { try body(); return nil } catch { return error as? MaerSyncFailure }
    }

    // MARK: - The answers

    @Test("Fassung 6: 428, 429 mit Retry-After und das zurueckgezogene Zeichen haben je ihren Namen")
    func versionSixAnswersHaveTheirNames() throws {
        #expect(failure { _ = try MaerSyncAnswer.token(MaerSyncReply(status: 428)) } == .operatorSetPassword)
        #expect(failure { _ = try MaerSyncAnswer.token(MaerSyncReply(status: 429, retryAfter: "120")) } == .tooManyAttempts(retryAfter: 120))
        #expect(failure { _ = try MaerSyncAnswer.token(MaerSyncReply(status: 429)) } == .tooManyAttempts(retryAfter: nil))
        #expect(failure { _ = try MaerSyncAnswer.password(MaerSyncReply(status: 429, retryAfter: "7")) } == .tooManyAttempts(retryAfter: 7))
        #expect(failure { _ = try MaerSyncAnswer.password(MaerSyncReply(status: 400)) } == .status(400))
        let withdrawn = MaerSyncReply(status: 401, refusal: "password-changed")
        #expect(failure { _ = try MaerSyncAnswer.document(withdrawn) } == .passwordChanged)
        #expect(failure { _ = try MaerSyncAnswer.written(withdrawn) } == .passwordChanged)
        #expect(failure { _ = try MaerSyncAnswer.listing(withdrawn) } == .passwordChanged)
        #expect(failure { _ = try MaerSyncAnswer.document(MaerSyncReply(status: 401)) } == .unauthorized, "a plain 401 stays what it was")
    }

    @Test("Fassung 6: das Salz wird gelesen, eine fremde Dehnung ist unlesbar, der Schluessel nennt seine Fassung")
    func saltAndKeyAreRead() throws {
        let body = Data("{\"salt\": \"AAECAwQFBgcICQoLDA0ODw==\", \"kdf\": \"pbkdf2-hmac-sha256\", \"rounds\": 600000, \"form\": \"secret\"}".utf8)
        let salt = try MaerSyncAnswer.salt(MaerSyncReply(status: 200, body: body))
        #expect(salt == MaerSyncSalt(salt: Data(0..<16), rounds: 600_000, form: .secret))
        let scrypt = Data("{\"salt\": \"AAECAwQFBgcICQoLDA0ODw==\", \"kdf\": \"scrypt\", \"rounds\": 600000, \"form\": \"proof\"}".utf8)
        #expect(failure { _ = try MaerSyncAnswer.salt(MaerSyncReply(status: 200, body: scrypt)) } == .unreadable)
        let raw = Data(repeating: 7, count: 32)
        let keyBody = try JSONSerialization.data(withJSONObject: ["key": raw.base64EncodedString(),
                                                                  "fingerprint": ServiceKeyFingerprint.written(for: raw)!])
        #expect(try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 200, contract: "6", body: keyBody)).contract == 6)
        #expect(try MaerSyncAnswer.serviceKey(MaerSyncReply(status: 200, body: keyBody)).contract == nil)
    }

    @Test("Wartezeit: Sekunden werden zu ganzen Minuten, aufgerundet, mindestens eine")
    func waitIsSaidInWholeMinutes() {
        #expect(MaerSyncWait.minutes(0) == 1)
        #expect(MaerSyncWait.minutes(1) == 1)
        #expect(MaerSyncWait.minutes(60) == 1)
        #expect(MaerSyncWait.minutes(61) == 2)
        #expect(MaerSyncWait.minutes(900) == 15)
        #expect(MaerSyncWait.minutes(-5) == 1)
    }

    // MARK: - The flow

    @MainActor
    private func signIn(_ transport: MaerSyncCarrierTests.FakeTransport, password: String = "ein langes passwort") async -> MaerSyncSignIn.Outcome {
        await MaerSyncSignIn.perform(address: "https://v6.example.test", owner: "owner-a", password: password,
                                     device: "dev-a", transport: transport)
    }

    @MainActor
    private func withCleanPin(_ body: () async throws -> Void) async rethrows {
        let account = ServiceKeyPin.account(for: URL(string: "https://v6.example.test")!)!
        KeychainStore.delete(forKey: account)
        defer { KeychainStore.delete(forKey: account) }
        try await body()
    }

    @Test("Fassung 6: angemeldet wird nur mit dem Beweis, und er ist die Ableitung aus Passwort und Salz")
    @MainActor
    func signInSendsOnlyTheProof() async throws {
        try await withCleanPin {
            let transport = MaerSyncCarrierTests.FakeTransport()
            let outcome = await signIn(transport)
            #expect(outcome == .signedIn(MaerSyncAccess(baseURL: URL(string: "https://v6.example.test")!, token: "a-token"), account: "owner-a"))
            let expected = try SignInDerivation.derive(password: "ein langes passwort", salt: Data(repeating: 1, count: 16),
                                                       rounds: 600_000).proofBase64
            #expect(transport.lastProof == expected, "the token way carried the proof of this password and this salt")
            #expect(transport.saltRequests == 1 && transport.tokenRequests == 1)
            #expect(transport.passwordChanges.isEmpty)
        }
    }

    @Test("Fassung 6: ein Konto in Form secret meldet sich nicht an, und nichts vom Passwort reist")
    @MainActor
    func formSecretStopsBeforeAnythingTravels() async {
        await withCleanPin {
            let transport = MaerSyncCarrierTests.FakeTransport()
            transport.saltForm = .secret
            #expect(await signIn(transport) == .needsNewPassword)
            #expect(transport.tokenRequests == 0, "no token way")
            #expect(transport.passwordChanges.isEmpty, "no change without a new password")
        }
    }

    @Test("Fassung 6: ein neuerer Dienst wird gesagt, bevor das Salz gefragt wird")
    @MainActor
    func aNewerServiceIsSaidFirst() async {
        await withCleanPin {
            let transport = MaerSyncCarrierTests.FakeTransport()
            transport.serviceContract = 7
            #expect(await signIn(transport) == .serviceIsNewer(7))
            #expect(transport.saltRequests == 0 && transport.tokenRequests == 0)
        }
    }

    @Test("Fassung 6: eine Dehnung, die das Geraet nicht annimmt, und zu viele Fehlversuche haben ihren Ausgang")
    @MainActor
    func refusedParametersAndTooManyAttempts() async {
        await withCleanPin {
            let transport = MaerSyncCarrierTests.FakeTransport()
            transport.saltRounds = 599_999
            #expect(await signIn(transport) == .unsafeParameters)
            #expect(transport.tokenRequests == 0, "nothing was sent")
            transport.saltRounds = 600_000
            transport.tooManyAttempts = .some(120)
            #expect(await signIn(transport) == .tooManyAttempts(retryAfter: 120))
        }
    }

    // MARK: - The way back does not exist

    @Test("Rueckfallverbot: ein Dienst der Fassung 5 ist aelter, und weder der alte Schluesselpfad noch ein Passwort geht hinaus")
    @MainActor
    func aVersionFiveServiceGetsNothing() async throws {
        let base = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
        let account = try #require(ServiceKeyPin.account(for: base))
        defer { KeychainStore.delete(forKey: account) }
        let service = MaerSyncTunnelTests.FakeService()
        await service.set(speaksVersion5: true)
        let door = MaerSyncHTTP(tunnels: MaerSyncTunnels { try await service.answer($0) }) { try await service.answer($0) }
        let outcome = await MaerSyncSignIn.perform(address: base.absoluteString, owner: "owner-a",
                                                   password: "ein langes passwort", device: "dev-a", transport: door)
        #expect(outcome == .serviceIsOlder)
        #expect(await service.plainPaths == ["/v2/key"], "one question, on the new path, and nothing after it")
        #expect(await service.innerTargets.isEmpty, "no session, no salt, no token")
        #expect(ServiceKeyPin.held(for: base) == nil, "nothing was held")
    }

    /// The source of the way back, counted without comments.
    nonisolated static func stripped(_ file: URL) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
    }

    nonisolated static func secretBuilders(in text: String) -> Int {
        text.components(separatedBy: "MaerSyncCurrent.secret(").count - 1
            + (text.range(of: #"current:\s*\.secret\("#, options: .regularExpression) == nil ? 0 : 1)
    }

    @Test("Rueckfallverbot: secret steht nur im Wechsel, gebaut wird es nirgends, und den alten Schluesselpfad kennt kein Code")
    func theWayBackIsFenced() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let net = root.appendingPathComponent("Sources/Networking")
        var syncText = ""
        for name in ["MaerSyncClient.swift", "MaerSyncSignIn.swift", "MaerSyncCarriers.swift", "MaerSyncTunnel.swift"] {
            syncText += try Self.stripped(net.appendingPathComponent(name)) + "\n"
        }
        // The password itself has one key in a body, and it lives in the
        // change; a second one would be the old sign-in coming back.
        #expect(syncText.components(separatedBy: "\"secret\"").count - 1 == 1)
        // From the door on: the first `func changePassword(` is the
        // protocol's declaration, which has no body.
        let door = try #require(syncText.range(of: "final class MaerSyncHTTP"))
        let change = try #require(syncText.range(of: "func changePassword(", range: door.upperBound..<syncText.endIndex))
        let rest = syncText[change.upperBound...]
        let end = rest.range(of: "\n    func ") ?? rest.range(of: "\n}")
        let changeBody = String(rest[..<(end?.lowerBound ?? rest.endIndex)])
        #expect(changeBody.contains("\"secret\""), "and it is the change's")

        var all = ""
        for file in ProjectFileIntegrityTests.sourceFiles() { all += try Self.stripped(file) + "\n" }
        #expect(!all.isEmpty && all.contains("MaerSyncCurrent"), "the precondition: the sources were read")
        #expect(Self.secretBuilders(in: all) == 0, "no code builds a password as the current credential")
        #expect(!all.contains("v1/key"), "no code knows the old key path")
        // Calibration: the counters see the forms they are for.
        #expect(Self.secretBuilders(in: "let c = MaerSyncCurrent.secret(old)") == 1)
        #expect(Self.secretBuilders(in: "changePassword(current: .secret(old))") == 1)
        #expect(Self.secretBuilders(in: "case .secret(let password):") == 0)
    }

    // MARK: - The cases of the service, replayed through the door

    nonisolated static let casesDigest = "57b1c873dbaa6fe9158b1b5562999af69aec0235ec9ddf11fe8de5d4344cc657"

    nonisolated static func casesURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/SignIn/faelle-v6.json")
    }

    /// Every request of the case file, the steps of the flows included.
    nonisolated static func requests() throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: casesURL())) as? [String: Any] ?? [:]
        var out: [[String: Any]] = []
        for item in object["faelle"] as? [[String: Any]] ?? [] { out.append(item["anfrage"] as? [String: Any] ?? [:]) }
        for flow in object["ablaeufe"] as? [[String: Any]] ?? [] {
            for step in flow["schritte"] as? [[String: Any]] ?? [] { out.append(step["anfrage"] as? [String: Any] ?? [:]) }
        }
        return out
    }

    @Test("Fassung 6: die Fall-Datei ist die, gegen die der Dienst laeuft")
    func theCasesAreTheServicesFile() throws {
        let digest = SHA256.hash(data: try Data(contentsOf: Self.casesURL())).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.casesDigest)
    }

    @Test("Fassung 6: jede Anmelde-Anfrage der Faelle, die die App bauen darf, baut die echte Tuer genauso")
    @MainActor
    func theDoorBuildsTheCasesRequests() async throws {
        let base = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
        let account = try #require(ServiceKeyPin.account(for: base))
        defer { KeychainStore.delete(forKey: account) }
        let service = MaerSyncTunnelTests.FakeService()
        let door = MaerSyncHTTP(tunnels: MaerSyncTunnels { try await service.answer($0) }) { try await service.answer($0) }
        var replayed = (salt: 0, token: 0, password: 0)
        var neverBuilt = 0
        for request in try Self.requests() where request["innen"] as? Bool == true {
            let method = request["method"] as? String ?? ""
            let path = request["path"] as? String ?? ""
            let body = (request["koerper_b64"] as? String).flatMap { Data(base64Encoded: $0) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let expectedTarget = "\(method) \(path)" + ((request["query"] as? String).map { "?\($0)" } ?? "")
            let before = await service.innerTargets.count
            switch (method, path) {
            case ("GET", "/v1/salt"):
                let owner = String((request["query"] as? String ?? "").dropFirst("owner=".count))
                _ = try? await door.salt(owner: owner, at: base)
                replayed.salt += 1
            case ("POST", "/v1/token") where body.map { Set($0.keys) } == ["owner", "proof", "device"]:
                _ = try? await door.token(owner: body!["owner"] as! String, proof: body!["proof"] as! String,
                                          device: body!["device"] as! String, at: base)
                replayed.token += 1
            case ("POST", "/v1/token"):
                neverBuilt += 1
                continue
            case ("POST", "/v1/password"):
                let current = try #require(body?["current"] as? [String: String])
                let new = try #require(body?["new"] as? [String: Any])
                let credential: MaerSyncCurrent = current["secret"].map { .secret($0) } ?? .proof(current["proof"]!)
                _ = try? await door.changePassword(
                    owner: body!["owner"] as! String, device: body!["device"] as! String, current: credential,
                    new: MaerSyncNewPassword(proof: new["proof"] as! String,
                                             salt: try #require(Data(base64Encoded: new["salt"] as! String)),
                                             rounds: new["rounds"] as! Int),
                    at: base)
                replayed.password += 1
            default:
                continue
            }
            let targets = await service.innerTargets
            try #require(targets.count == before + 1, "the door sent exactly one request")
            #expect(targets.last == expectedTarget)
            if let body {
                let sent = try JSONSerialization.jsonObject(with: try #require(await service.innerBodies.last)) as? [String: Any] ?? [:]
                #expect(NSDictionary(dictionary: sent).isEqual(to: body), "\(expectedTarget): the body is the case's")
            }
        }
        // Counted independently from the file before this witness existed.
        #expect(replayed.salt == 8 && replayed.token == 21 && replayed.password == 13)
        #expect(neverBuilt == 7, "the token requests with a password the app has no way to build")
    }
}
#endif
