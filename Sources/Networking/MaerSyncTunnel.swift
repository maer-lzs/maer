// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// What the tunnel needs of the network: a request in, bytes and a response
/// out. Injectable so a witness can stand in for the service with a real
/// Noise responder, which is the only way to drive the sealing without a
/// host.
typealias MaerSyncWire = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse?)

/// One open session: its name and the two transport keys. An actor, because
/// the keys count their messages and a counter shared between two tasks
/// would be a nonce used twice.
actor MaerSyncLine {
    let name: String
    private let sender: NoiseCipherState
    private let receiver: NoiseCipherState

    init(name: String, send: NoiseCipherState, receive: NoiseCipherState) {
        self.name = name
        sender = send
        receiver = receive
    }

    func seal(_ plaintext: Data) throws -> Data { try sender.encrypt(ad: Data(), plaintext: plaintext) }
    func unseal(_ ciphertext: Data) throws -> Data { try receiver.decrypt(ad: Data(), ciphertext: ciphertext) }
}

/// The encrypted session to one service, and every request that goes
/// through it.
///
/// **One request at a time, on purpose.** The transport keys count their
/// messages, and messages must open in the order they were sealed; two in
/// flight could arrive the other way round and the second would not open.
/// Exchanges therefore form a chain, each waiting for the one before it,
/// which is the same construction the rounds of the session use.
///
/// **A session that ended costs one handshake and one retry, and nobody
/// hears about it.** The service says 410 after an hour of silence, after a
/// day in any case, and after every restart; the answer is a fresh
/// handshake and the same request once more.
///
/// **The meeting is the handshake.** Before the first message the service's
/// key is fetched and its fingerprint computed from the bytes and set
/// against the one this device holds: nothing held means this is the first
/// meeting and the key is held from now on; the same key means nothing;
/// a DIFFERENT key stops everything with `serviceKeyChanged`, and no
/// handshake is sent to whoever offered it. The rounds stop on that until a
/// person has looked at both fingerprints on the settings page.
actor MaerSyncTunnel {
    let base: URL
    private let wire: MaerSyncWire
    private var line: MaerSyncLine?
    private var chain: Task<Void, Never>?

    init(base: URL, wire: @escaping MaerSyncWire = { try await HTTP.data(for: $0, retry: false) }) {
        self.base = base
        self.wire = wire
    }

    /// The meeting, then the handshake: a fresh line for a service.
    ///
    /// Used by the request tunnel and by the changes socket, which wants a
    /// line of its own: a stream of announcements interleaved with the
    /// replies of a request session would race its counter.
    static func handshake(at base: URL, wire: MaerSyncWire) async throws -> MaerSyncLine {
        let (keyBytes, keyResponse) = try await wire(URLRequest(url: MaerSyncPaths.key(base)))
        guard let keyResponse else { throw MaerSyncFailure.unreadable }
        let offeredKey = try MaerSyncAnswer.serviceKey(MaerSyncReply(keyResponse, body: keyBytes))
        let (key, offered) = (offeredKey.key, offeredKey.fingerprint)
        switch ServiceKeyTrust.standing(held: ServiceKeyPin.held(for: base), offered: offered) {
        case .changed(let held, let offered):
            Logger.library.error("MAERSYNC the service at \(base.host ?? "-", privacy: .public) offers a different key than the one held; nothing runs until somebody looks")
            throw MaerSyncFailure.serviceKeyChanged(held: held, offered: offered)
        case .first:
            // The first meeting of a device that is already signed in: the
            // sign-in holds the key for new sign-ins, this holds it for
            // devices that were signed in before there was a key to hold.
            ServiceKeyPin.hold(offered, for: base)
        case .unchanged:
            break
        }
        let handshake = NoiseHandshake(initiator: true, remoteStatic: key)
        var request = URLRequest(url: MaerSyncPaths.session(base))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = try handshake.writeMessage()
        let (data, response) = try await wire(request)
        guard let response else { throw MaerSyncFailure.unreadable }
        let (reply, name) = try MaerSyncAnswer.session(MaerSyncReply(response, body: data))
        _ = try handshake.readMessage(reply)
        let keys = try handshake.split()
        return MaerSyncLine(name: name, send: keys.send, receive: keys.receive)
    }

    /// One ordinary request of the service, sealed, and its ordinary reply.
    func exchange(method: String, target: String, headers: [String: String],
                  body: Data) async throws -> MaerSyncReply {
        let previous = chain
        let run = Task<MaerSyncReply, Error> {
            await previous?.value
            return try await self.perform(method: method, target: target, headers: headers, body: body)
        }
        chain = Task { _ = await run.result }
        return try await run.value
    }

    private func perform(method: String, target: String, headers: [String: String],
                         body: Data) async throws -> MaerSyncReply {
        let frame = try MaerSyncFrame.pack(head: MaerSyncFrame.requestHead(method: method, target: target,
                                                                            headers: headers), body: body)
        do {
            return try await send(frame, over: current())
        } catch MaerSyncFailure.sessionEnded {
            // Once. A second 410 in a row is not a session that ended, it is
            // a service that cannot keep one, and that is worth a log line
            // at the caller instead of a loop here.
            line = nil
            do {
                return try await send(frame, over: current())
            } catch {
                dropLine(after: error)
                throw error
            }
        } catch {
            dropLine(after: error)
            throw error
        }
    }

    /// Any failure once a request was sealed leaves the line's counters in
    /// doubt: the request may have reached the service and its reply may
    /// not have reached this device. Measured on 24.09.: a connection lost
    /// mid-request (`urlError=-1005`), after that EVERY reply of the session
    /// failed to open (`CryptoKitError`, ten requests in one minute), because
    /// the service had counted a reply this device never read. The line is
    /// spent; the next request meets the service anew, which costs one
    /// handshake.
    private func dropLine(after error: Error) {
        guard line != nil else { return }
        line = nil
        Logger.library.notice("MAERSYNC session line dropped after reason=\(MaerSyncFailure.reason(of: error), privacy: .public); the next request meets anew")
    }

    private func current() async throws -> MaerSyncLine {
        if let line { return line }
        let fresh = try await Self.handshake(at: base, wire: wire)
        line = fresh
        return fresh
    }

    private func send(_ frame: Data, over line: MaerSyncLine) async throws -> MaerSyncReply {
        var request = URLRequest(url: MaerSyncPaths.session(base))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(line.name, forHTTPHeaderField: "X-Maer-Session")
        request.httpBody = try await line.seal(frame)
        let (data, response) = try await wire(request)
        guard let response else { throw MaerSyncFailure.unreadable }
        let sealed = try MaerSyncAnswer.tunnel(MaerSyncReply(response, body: data))
        let (head, replyBody) = try MaerSyncFrame.unpack(try await line.unseal(sealed))
        let (status, replyHeaders) = try MaerSyncFrame.reply(of: head)
        return MaerSyncReply(status: status, lowercasedHeaders: replyHeaders, body: replyBody)
    }
}

/// One tunnel per service address for one door, so every way of that door
/// shares a session and one request is in flight per service at a time.
/// Not process wide on purpose: a door is made where it is used (the
/// session's factory, a sign-in), and a second door means a second session,
/// which costs a handshake and nothing else.
actor MaerSyncTunnels {
    private var tunnels: [String: MaerSyncTunnel] = [:]
    private let wire: MaerSyncWire

    init(wire: @escaping MaerSyncWire = { try await HTTP.data(for: $0, retry: false) }) {
        self.wire = wire
    }

    func tunnel(for base: URL) -> MaerSyncTunnel {
        let name = ServiceKeyPin.account(for: base) ?? base.absoluteString
        if let held = tunnels[name] { return held }
        let fresh = MaerSyncTunnel(base: base, wire: wire)
        tunnels[name] = fresh
        return fresh
    }
}
