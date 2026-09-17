// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import CryptoKit
import Foundation
@testable import Maer

/// The tunnel against a service stood in by a REAL Noise responder: the
/// other half of the handshake in this language, answering the key path,
/// the handshake, and sealed requests with canned inner replies. What is
/// measured is the part only the tunnel can get wrong: one handshake serves
/// many requests, an ended session costs one handshake and one retry, two
/// requests never overtake each other, and a changed key stops everything
/// before a handshake is sent.
@MainActor
struct MaerSyncTunnelTests {
    /// The service, as far as the tunnel can tell.
    actor FakeService {
        let key = Curve25519.KeyAgreement.PrivateKey()
        private var sessions: [String: (send: NoiseCipherState, receive: NoiseCipherState)] = [:]
        var handshakes = 0
        var sealedRequests = 0
        var innerTargets: [String] = []
        var innerHeaders: [[String: String]] = []
        /// Every session is forgotten before the next sealed request.
        var forgetNext = false
        /// What the inner request is answered with.
        var inner: @Sendable (String, String, Data) -> (Int, [String: String], Data) = { _, _, _ in
            (404, ["content-type": "application/json"], Data("{\"reason\": \"no such document\"}".utf8))
        }

        var fingerprint: String { ServiceKeyFingerprint.written(for: key.publicKey.rawRepresentation)! }
        var lastName: String? { sessions.keys.first }

        func set(inner: @escaping @Sendable (String, String, Data) -> (Int, [String: String], Data)) { self.inner = inner }
        func set(forgetNext: Bool) { self.forgetNext = forgetNext }

        private func response(_ status: Int, _ url: URL, headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        }

        func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse?) {
            let url = request.url!
            if url.path.hasSuffix("/v1/key") {
                let body = try JSONSerialization.data(withJSONObject: [
                    "key": key.publicKey.rawRepresentation.base64EncodedString(), "fingerprint": fingerprint])
                return (body, response(200, url))
            }
            guard url.path.hasSuffix("/v1/session") else { return (Data(), response(404, url)) }
            if let name = request.value(forHTTPHeaderField: "X-Maer-Session") {
                sealedRequests += 1
                if forgetNext { sessions = [:]; forgetNext = false }
                guard let keys = sessions[name] else {
                    return (Data("{\"reason\": \"this session has ended\"}".utf8), response(410, url))
                }
                guard let opened = try? keys.receive.decrypt(ad: Data(), ciphertext: request.httpBody ?? Data()),
                      let (head, body) = try? MaerSyncFrame.unpack(opened),
                      let method = head["method"] as? String, let target = head["target"] as? String
                else { return (Data(), response(400, url)) }
                innerTargets.append("\(method) \(target)")
                innerHeaders.append((head["headers"] as? [String: String]) ?? [:])
                let (status, replyHeaders, replyBody) = inner(method, target, body)
                let frame = try MaerSyncFrame.pack(head: ["status": status, "headers": replyHeaders], body: replyBody)
                return (try keys.send.encrypt(ad: Data(), plaintext: frame), response(200, url))
            }
            handshakes += 1
            let responder = NoiseHandshake(initiator: false, staticPrivate: key)
            _ = try responder.readMessage(request.httpBody ?? Data())
            let reply = try responder.writeMessage()
            let split = responder.split()
            let name = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            sessions[name] = (split.send, split.receive)
            return (reply, response(200, url, headers: ["X-Maer-Session": name]))
        }
    }

    private func host() -> URL { URL(string: "https://\(UUID().uuidString.lowercased()).test")! }

    private func tunnel(_ service: FakeService, at base: URL) -> MaerSyncTunnel {
        MaerSyncTunnel(base: base) { request in try await service.answer(request) }
    }

    @Test("ein Handschlag traegt viele Anfragen, und innen reist die gewoehnliche Anfrage samt Zeichen")
    func oneHandshakeCarriesManyRequests() async throws {
        let base = host()
        defer { KeychainStore.delete(forKey: ServiceKeyPin.account(for: base)!) }
        let service = FakeService()
        await service.set { method, target, body in
            (200, ["ETag": "3", "X-Maer-Format": "1"], Data("\(method) \(target) \(body.count)".utf8))
        }
        let tunnel = tunnel(service, at: base)
        for n in 1...3 {
            let reply = try await tunnel.exchange(method: "PUT", target: "/v1/doc/stands?scope=",
                                                  headers: ["Authorization": "Bearer t"], body: Data(repeating: 1, count: n))
            #expect(reply.status == 200 && reply.etag == "3" && reply.format == "1")
            #expect(reply.body == Data("PUT /v1/doc/stands?scope= \(n)".utf8))
        }
        #expect(await service.handshakes == 1)
        #expect(await service.sealedRequests == 3)
        #expect(await service.innerHeaders.first?["Authorization"] == "Bearer t", "the token rides inside")
        #expect(ServiceKeyPin.held(for: base) == (await service.fingerprint), "the first meeting held the key")
    }

    @Test("eine beendete Sitzung kostet einen Handschlag und eine Wiederholung, sonst nichts")
    func anEndedSessionCostsOneHandshakeAndOneRetry() async throws {
        let base = host()
        defer { KeychainStore.delete(forKey: ServiceKeyPin.account(for: base)!) }
        let service = FakeService()
        let tunnel = tunnel(service, at: base)
        _ = try await tunnel.exchange(method: "GET", target: "/v1/doc/stands", headers: [:], body: Data())
        await service.set(forgetNext: true)
        let reply = try await tunnel.exchange(method: "GET", target: "/v1/doc/stands", headers: [:], body: Data())
        #expect(reply.status == 404, "the request went through after all")
        #expect(await service.handshakes == 2)
        #expect(await service.sealedRequests == 3, "one that met the 410, one that landed")
    }

    @Test("zwei Anfragen ueberholen sich nie: fuenf auf einmal gehen alle auf")
    func requestsNeverOvertakeEachOther() async throws {
        let base = host()
        defer { KeychainStore.delete(forKey: ServiceKeyPin.account(for: base)!) }
        let service = FakeService()
        let tunnel = tunnel(service, at: base)
        // Without the chain, five sealed at once would reach the fake in
        // some order, and the counter of the responder opens only the next
        // one: everything else is a 400.
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 1...5 {
                group.addTask {
                    try await tunnel.exchange(method: "GET", target: "/v1/doc/stands", headers: [:], body: Data()).status
                }
            }
            var statuses: [Int] = []
            for try await status in group { statuses.append(status) }
            #expect(statuses == [404, 404, 404, 404, 404])
        }
        #expect(await service.handshakes == 1)
    }

    @Test("ein anderer Schluessel haelt alles an, bevor ein Handschlag hinausgeht")
    func aDifferentKeyStopsBeforeAnyHandshake() async throws {
        let base = host()
        defer { KeychainStore.delete(forKey: ServiceKeyPin.account(for: base)!) }
        ServiceKeyPin.hold("9ER6-Z3JE-79VH-BMG1-TNSX-1AJ2", for: base)
        let service = FakeService()
        let tunnel = tunnel(service, at: base)
        let offered = await service.fingerprint
        await #expect(throws: MaerSyncFailure.serviceKeyChanged(held: "9ER6-Z3JE-79VH-BMG1-TNSX-1AJ2", offered: offered)) {
            try await tunnel.exchange(method: "GET", target: "/v1/doc/stands", headers: [:], body: Data())
        }
        #expect(await service.handshakes == 0, "nothing was sent to whoever offered the key")
        #expect(ServiceKeyPin.held(for: base) == "9ER6-Z3JE-79VH-BMG1-TNSX-1AJ2", "the held key is untouched")
    }

    @Test("die Tuer schickt die drei Wege und die Anmeldung durch den Tunnel")
    func theDoorGoesThroughTheTunnel() async throws {
        let base = host()
        defer { KeychainStore.delete(forKey: ServiceKeyPin.account(for: base)!) }
        let service = FakeService()
        await service.set { method, target, body in
            if target == "/v1/token" { return (200, [:], Data("{\"token\": \"t-9\"}".utf8)) }
            if method == "PUT" { return (200, ["ETag": "5"], Data()) }
            if target.hasPrefix("/v1/docs/") { return (200, [:], Data("{\"documents\": []}".utf8)) }
            return (200, ["ETag": "4", "X-Maer-Format": "1"], Data("{\"k\":\"v\"}".utf8))
        }
        let tunnels = MaerSyncTunnels { request in try await service.answer(request) }
        let door = MaerSyncHTTP(tunnels: tunnels) { request in try await service.answer(request) }
        let access = MaerSyncAccess(baseURL: base, token: "t-9")
        #expect(try await door.token(owner: "the-owner", secret: "s", device: "d", at: base) == "t-9")
        #expect(try await door.fetch(kind: "stands", scope: "", access: access)?.etag == "4")
        #expect(try await door.write(kind: "stands", scope: "", body: Data("{}".utf8), format: 1, ifMatch: "4",
                                     declaredShrink: false, access: access) == .written(etag: "5"))
        #expect(try await door.list(kind: "claim", access: access) == [])
        #expect(await service.handshakes == 1, "one session for the sign-in and every way after it")
        let targets = await service.innerTargets
        #expect(targets == ["POST /v1/token", "GET /v1/doc/stands", "PUT /v1/doc/stands", "GET /v1/docs/claim"])
        let headers = await service.innerHeaders
        #expect(headers[0]["Authorization"] == nil, "the sign-in has no token yet")
        #expect(headers[1]["Authorization"] == "Bearer t-9")
        #expect(headers[2]["If-Match"] == "4" && headers[2]["X-Maer-Format"] == "1")
    }
}
#endif
