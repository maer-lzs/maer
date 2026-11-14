// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import CryptoKit
import Foundation
@testable import Maer

/// The device's handshake against SOMEBODY ELSE'S numbers, and then against
/// itself.
///
/// **The order matters, and it is the whole argument of this file.** A round
/// trip proves that a construction agrees with itself, and a construction
/// that is subtly not Noise agrees with itself perfectly. It would also agree
/// with our own service, because the two halves were written by the same hand
/// on the same day: **testing them against each other would prove nothing at
/// all.** So the first case replays published vectors byte for byte, from two
/// implementations in different languages that do not know each other and
/// that used different keys. Only after that do the behaviour cases run.
///
/// The vectors are the same file the service keeps, copied verbatim with its
/// provenance. Not fetched: a suite that reaches the network measures the
/// network.
struct NoiseNKTests {
    // MARK: - The fixture

    nonisolated struct Vector: Decodable {
        let protocol_name: String
        let init_prologue: String
        let init_remote_static: String
        let init_ephemeral: String
        let resp_prologue: String
        let resp_static: String
        let resp_ephemeral: String
        let handshake_hash: String?
        let messages: [Message]

        nonisolated struct Message: Decodable {
            let payload: String
            let ciphertext: String
        }
    }

    nonisolated struct Vectors: Decodable { let vectors: [Vector] }

    nonisolated static func fixture() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Noise/noise-nk.json")
        return try JSONDecoder().decode(Vectors.self, from: try Data(contentsOf: url))
    }

    nonisolated static func bytes(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    nonisolated static func key(_ hex: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(hex))
    }

    // MARK: - Somebody else's numbers

    @Test("both published vectors come out byte for byte", .needsTheTests)
    func bothPublishedVectorsAreReproducedByteForByte() throws {
        let vectors = try Self.fixture().vectors
        // The precondition, and without it this file could pass while
        // measuring nothing: there are two, and they are not one twice.
        try #require(vectors.count == 2)
        #expect(vectors[0].init_ephemeral != vectors[1].init_ephemeral,
                "zwei Vektoren mit denselben Schluesseln waeren ein Vektor")

        for vector in vectors {
            #expect(vector.protocol_name == "Noise_NK_25519_ChaChaPoly_SHA256")
            try Self.replay(vector)
        }
    }

    nonisolated static func replay(_ vector: Vector) throws {
        let initiator = NoiseHandshake(
            initiator: true,
            prologue: bytes(vector.init_prologue),
            remoteStatic: bytes(vector.init_remote_static),
            ephemeralPrivate: try key(vector.init_ephemeral))
        let responder = NoiseHandshake(
            initiator: false,
            prologue: bytes(vector.resp_prologue),
            staticPrivate: try key(vector.resp_static),
            ephemeralPrivate: try key(vector.resp_ephemeral))

        let first = try initiator.writeMessage(bytes(vector.messages[0].payload))
        #expect(first.hexed == vector.messages[0].ciphertext,
                "die erste Nachricht ist nicht die veroeffentlichte")
        #expect(try responder.readMessage(first).hexed == vector.messages[0].payload)

        let second = try responder.writeMessage(bytes(vector.messages[1].payload))
        #expect(second.hexed == vector.messages[1].ciphertext,
                "die Antwort ist nicht die veroeffentlichte")
        #expect(try initiator.readMessage(second).hexed == vector.messages[1].payload)

        // The handshake hash is what a later channel binding would stand on,
        // so it is held even though nothing uses it yet.
        if let expected = vector.handshake_hash {
            #expect(initiator.handshakeHash.hexed == expected)
            #expect(responder.handshakeHash.hexed == expected)
        }

        let (initiatorSend, initiatorReceive) = try initiator.split()
        let (responderSend, responderReceive) = try responder.split()
        for index in 2..<vector.messages.count {
            let message = vector.messages[index]
            let writer = index % 2 == 0 ? initiatorSend : responderSend
            let reader = index % 2 == 0 ? responderReceive : initiatorReceive
            let sealed = try writer.encrypt(ad: Data(), plaintext: bytes(message.payload))
            #expect(sealed.hexed == message.ciphertext,
                    "Transport-Nachricht \(index) ist nicht die veroeffentlichte")
            #expect(try reader.decrypt(ad: Data(), ciphertext: bytes(message.ciphertext)).hexed
                    == message.payload)
        }
    }

    // MARK: - And then against itself

    nonisolated static func pair(responderStatic: Curve25519.KeyAgreement.PrivateKey? = nil,
                                 initiatorBelieves: Data? = nil)
        -> (NoiseHandshake, NoiseHandshake) {
        let responderKey = responderStatic ?? Curve25519.KeyAgreement.PrivateKey()
        let believed = initiatorBelieves ?? responderKey.publicKey.rawRepresentation
        return (NoiseHandshake(initiator: true, remoteStatic: believed),
                NoiseHandshake(initiator: false, staticPrivate: responderKey))
    }

    @Test("a fresh pair agrees in both directions")
    func aFreshPairAgreesBothWays() throws {
        let (initiator, responder) = Self.pair()
        _ = try responder.readMessage(try initiator.writeMessage(Data("hello".utf8)))
        _ = try initiator.readMessage(try responder.writeMessage(Data("there".utf8)))
        let (send, receive) = try initiator.split()
        let (responderSend, responderReceive) = try responder.split()
        let sealed = try send.encrypt(ad: Data(), plaintext: Data("a position".utf8))
        #expect(try responderReceive.decrypt(ad: Data(), ciphertext: sealed) == Data("a position".utf8))
        let back = try responderSend.encrypt(ad: Data(), plaintext: Data("an answer".utf8))
        #expect(try receive.decrypt(ad: Data(), ciphertext: back) == Data("an answer".utf8))
    }

    @Test("two handshakes never look alike")
    func twoHandshakesNeverLookAlike() throws {
        // Without a fresh ephemeral per handshake the whole thing collapses,
        // and nothing in a round trip would notice.
        let (first, _) = Self.pair()
        let (second, _) = Self.pair()
        #expect(try first.writeMessage(Data("x".utf8)) != (try second.writeMessage(Data("x".utf8))))
    }

    @Test("the wrong static key gets no session")
    func theWrongStaticKeyGetsNoSession() throws {
        // Exactly the swapped counterpart: somebody answers, but not the one
        // whose key is pinned. It must fail, not quietly work.
        let real = Curve25519.KeyAgreement.PrivateKey()
        let stranger = Curve25519.KeyAgreement.PrivateKey()
        let initiator = NoiseHandshake(initiator: true,
                                       remoteStatic: stranger.publicKey.rawRepresentation)
        let responder = NoiseHandshake(initiator: false, staticPrivate: real)
        let message = try initiator.writeMessage(Data("hello".utf8))
        #expect(throws: (any Error).self) { try responder.readMessage(message) }
    }

    @Test("an altered byte is rejected")
    func aChangedByteIsRefused() throws {
        let (initiator, responder) = Self.pair()
        var message = try initiator.writeMessage(Data("hello".utf8))
        // Relative to `startIndex`, never to zero: a `Data` does not have to
        // begin at 0, and the neighbour below crashed on exactly that.
        message[message.index(before: message.endIndex)] ^= 0x01
        #expect(throws: (any Error).self) { try responder.readMessage(message) }
    }

    @Test("a different prologue gets no session")
    func aDifferentPrologueGetsNoSession() throws {
        // The prologue is where the two sides state what they agreed on
        // before speaking. If they disagree, the session must not come up.
        let responderKey = Curve25519.KeyAgreement.PrivateKey()
        let initiator = NoiseHandshake(initiator: true, prologue: Data("v1".utf8),
                                       remoteStatic: responderKey.publicKey.rawRepresentation)
        let responder = NoiseHandshake(initiator: false, prologue: Data("v2".utf8),
                                       staticPrivate: responderKey)
        let message = try initiator.writeMessage(Data("hello".utf8))
        #expect(throws: (any Error).self) { try responder.readMessage(message) }
    }

    @Test("the counter runs, so a nonce is never reused")
    func theCounterMovesSoANonceIsNeverReused() throws {
        let (initiator, responder) = Self.pair()
        _ = try responder.readMessage(try initiator.writeMessage())
        _ = try initiator.readMessage(try responder.writeMessage())
        let (send, _) = try initiator.split()
        let (_, responderReceive) = try responder.split()
        let first = try send.encrypt(ad: Data(), plaintext: Data("same".utf8))
        let second = try send.encrypt(ad: Data(), plaintext: Data("same".utf8))
        #expect(first != second, "derselbe Klartext zweimal darf nicht gleich versiegeln")
        #expect(try responderReceive.decrypt(ad: Data(), ciphertext: first) == Data("same".utf8))
        #expect(try responderReceive.decrypt(ad: Data(), ciphertext: second) == Data("same".utf8))
    }

    @Test("a forgery does not move the counter")
    func aForgeryDoesNotMoveTheCounter() throws {
        // If a refused message advanced the counter, the two sides would be
        // out of step from then on and the session would end for the honest
        // one. Anybody able to inject a single byte could do that.
        let (initiator, responder) = Self.pair()
        _ = try responder.readMessage(try initiator.writeMessage())
        _ = try initiator.readMessage(try responder.writeMessage())
        let (send, _) = try initiator.split()
        let (_, responderReceive) = try responder.split()
        let sealed = try send.encrypt(ad: Data(), plaintext: Data("real".utf8))
        var forged = sealed
        // `sealed` is `ciphertext + tag` from a `SealedBox`, and that `Data`
        // does NOT begin at zero: subscripting it with a literal 0 trapped
        // and took the whole run with it (884 of 1859 cases, the count was
        // the tell). Indices of a `Data` are relative to `startIndex`, and
        // concatenation does not normalise them.
        forged[forged.startIndex] ^= 0xFF
        #expect(throws: (any Error).self) {
            try responderReceive.decrypt(ad: Data(), ciphertext: forged)
        }
        #expect(try responderReceive.decrypt(ad: Data(), ciphertext: sealed) == Data("real".utf8),
                "die echte Nachricht muss danach noch aufgehen")
    }

    /// The pattern has two messages and each side one turn at each. A
    /// handshake that let a message be written twice, read out of turn or
    /// split early would hand out keys off a state the other side does not
    /// have, and nothing in a round trip would notice.
    @Test("a second first word throws")
    func aSecondFirstMessageThrows() throws {
        let (initiator, _) = Self.pair()
        _ = try initiator.writeMessage()
        #expect(throws: NoiseFailure.self) { try initiator.writeMessage() }
    }

    @Test("split before the end throws, afterwards not")
    func splitBeforeTheEndThrows() throws {
        let (initiator, responder) = Self.pair()
        #expect(throws: NoiseFailure.self) { try initiator.split() }
        _ = try responder.readMessage(try initiator.writeMessage())
        #expect(throws: NoiseFailure.self) { try initiator.split() }
        _ = try initiator.readMessage(try responder.writeMessage())
        _ = try initiator.split()
        _ = try responder.split()
    }

    @Test("a step out of order throws: the responder does not write first, the caller does not read first")
    func aStepOutOfTurnThrows() throws {
        let (initiator, responder) = Self.pair()
        #expect(throws: NoiseFailure.self) { try responder.writeMessage() }
        let first = try initiator.writeMessage()
        #expect(throws: NoiseFailure.self) { try initiator.writeMessage() }
        _ = try responder.readMessage(first)
        #expect(throws: NoiseFailure.self) { try responder.readMessage(first) }
        _ = try initiator.readMessage(try responder.writeMessage())
        #expect(throws: NoiseFailure.self) { try responder.writeMessage() }
        #expect(throws: NoiseFailure.self) { try initiator.readMessage(first) }
    }
}

nonisolated extension Data {
    var hexed: String { map { String(format: "%02x", $0) }.joined() }
}
#endif
