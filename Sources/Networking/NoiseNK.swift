// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CryptoKit
import Foundation

/// The device's half of the encrypted session with the sync service.
///
/// This is the same protocol the service speaks, written a second time in a
/// second language, and that is the point rather than an accident: the two
/// halves are never tested against each other. **Both are held against the
/// same two PUBLISHED vectors**, from implementations that know neither of
/// them. Two constructions that agree with each other can be wrong together;
/// only somebody else's numbers say otherwise.
///
/// **No invention here.** Noise, pattern `NK`, in the spelling of the
/// framework's revision 34:
///
///     Noise_NK_25519_ChaChaPoly_SHA256
///
/// `NK` because the device knows the service's static public key (it pins it)
/// and stays anonymous through the handshake. That anonymity is what lets a
/// SIGN IN be protected: the sign in carries the account secret and happens
/// before there is any token to prove anything with, so a pattern demanding a
/// static key from the caller could not protect the one exchange that matters
/// most.
///
/// **Measured before writing a line**, because the framework's spelling is
/// exact and a system library's convenience is not: `SealedBox` hands back
/// `ciphertext` and `tag` SEPARATELY, and its `combined` form prepends the
/// nonce, which Noise does not carry. Using `combined` would produce twelve
/// extra bytes per message and interoperate with nobody. The HKDF here is
/// built from `HMAC` rather than from `CryptoKit.HKDF` for the same reason:
/// the framework chains HMAC in a particular way, and writing that chain
/// out is the same construction the service uses, rather than a mapping onto
/// somebody else's parameter names that has to be argued about.
nonisolated enum NoiseNK {
    /// The one name, exactly 32 bytes, which the rule for the initial hash
    /// depends on: a name of at most HASHLEN bytes is used padded with zeros
    /// instead of hashed.
    static let protocolName = Data("Noise_NK_25519_ChaChaPoly_SHA256".utf8)
    static let hashLength = 32
    static let keyLength = 32
    static let tagLength = 16

    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// The framework's HKDF, which is HMAC chained and nothing else.
    static func hkdf(chainingKey: Data, material: Data, outputs: Int) -> [Data] {
        let tempKey = hmac(key: chainingKey, data: material)
        let out1 = hmac(key: tempKey, data: Data([0x01]))
        let out2 = hmac(key: tempKey, data: out1 + Data([0x02]))
        if outputs == 2 { return [out1, out2] }
        return [out1, out2, hmac(key: tempKey, data: out2 + Data([0x03]))]
    }

    /// X25519, the only agreement this protocol name allows.
    static func agree(private key: Curve25519.KeyAgreement.PrivateKey,
                      publicKey raw: Data) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        return try key.sharedSecretFromKeyAgreement(with: peer)
            .withUnsafeBytes { Data($0) }
    }
}

/// One direction's key and its counter.
///
/// The counter is the whole reason this is a type: a nonce reused with the
/// same key breaks ChaCha20-Poly1305 completely, so it may never come from
/// outside, only be counted here.
nonisolated final class NoiseCipherState {
    private var key: Data?
    private var counter: UInt64 = 0

    init(key: Data? = nil) { self.key = key }

    var hasKey: Bool { key != nil }

    /// The framework's nonce for this cipher: four zero bytes, then the
    /// counter as eight bytes, little endian. Any other spelling still
    /// encrypts and still interoperates with nobody.
    private func nonce() throws -> ChaChaPoly.Nonce {
        var raw = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.littleEndian) { raw.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: raw)
    }

    func encrypt(ad: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key),
                                      nonce: try nonce(), authenticating: ad)
        counter += 1
        // Ciphertext and tag, NOT `combined`: that form carries the nonce in
        // front of them, and Noise does not put the nonce on the wire.
        return box.ciphertext + box.tag
    }

    func decrypt(ad: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard ciphertext.count >= NoiseNK.tagLength else {
            throw NoiseFailure.tooShort
        }
        let cut = ciphertext.count - NoiseNK.tagLength
        let box = try ChaChaPoly.SealedBox(nonce: try nonce(),
                                           ciphertext: ciphertext.prefix(cut),
                                           tag: ciphertext.suffix(NoiseNK.tagLength))
        let plaintext = try ChaChaPoly.open(box, using: SymmetricKey(data: key),
                                            authenticating: ad)
        // Only after the message proved authentic, exactly like the other
        // half: a counter that moved on a forgery would put the two sides
        // out of step and end the session for the honest one.
        counter += 1
        return plaintext
    }
}

nonisolated enum NoiseFailure: Error {
    /// A handshake message carries an ephemeral key first, so anything
    /// shorter than one is not a handshake message.
    case notAHandshakeMessage
    /// A sealed message is at least its own tag.
    case tooShort
    /// A message written or read out of turn, or keys asked for before
    /// both messages were exchanged.
    case outOfStep
}

/// The chaining key and the running hash, as the framework names them.
nonisolated final class NoiseSymmetricState {
    private(set) var h: Data
    private var chainingKey: Data
    private var cipher = NoiseCipherState()

    init(protocolName: Data = NoiseNK.protocolName) {
        if protocolName.count <= NoiseNK.hashLength {
            h = protocolName + Data(repeating: 0, count: NoiseNK.hashLength - protocolName.count)
        } else {
            h = NoiseNK.hash(protocolName)
        }
        chainingKey = h
    }

    func mixKey(_ material: Data) {
        let out = NoiseNK.hkdf(chainingKey: chainingKey, material: material, outputs: 2)
        chainingKey = out[0]
        cipher = NoiseCipherState(key: out[1])
    }

    func mixHash(_ data: Data) { h = NoiseNK.hash(h + data) }

    func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(ad: h, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ad: h, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (NoiseCipherState, NoiseCipherState) {
        let out = NoiseNK.hkdf(chainingKey: chainingKey, material: Data(), outputs: 2)
        return (NoiseCipherState(key: out[0]), NoiseCipherState(key: out[1]))
    }
}

/// One side of `NK`, from its first message to its two transport keys.
///
/// Two messages and that is all: the caller sends its ephemeral key and mixes
/// in the agreement with the service's known static key, the service answers
/// with its own ephemeral and mixes in the agreement of the two ephemerals.
/// Whoever does not hold the service's private static key cannot produce the
/// second message, and that is exactly what pinning the key buys.
nonisolated final class NoiseHandshake {
    private let initiator: Bool
    private let symmetric: NoiseSymmetricState
    private let staticPrivate: Curve25519.KeyAgreement.PrivateKey?
    private let remoteStatic: Data?
    private var ephemeralPrivate: Curve25519.KeyAgreement.PrivateKey?
    private var remoteEphemeral: Data?
    /// The pattern has two messages, and each side takes one turn at each.
    /// Counted so that a second first message, a read out of turn or a
    /// split before the end throws instead of producing keys off a state
    /// that is not the one the other side has.
    private var messagesDone = 0

    var handshakeHash: Data { symmetric.h }

    /// Whose turn it is to write the message with this number.
    private func isMyTurnToWrite(_ number: Int) -> Bool {
        initiator ? number == 0 : number == 1
    }

    /// `ephemeralPrivate` is injectable ONLY so the published vectors can be
    /// replayed. Every other caller leaves it alone and gets a fresh key; a
    /// handshake that reuses an ephemeral is not a handshake.
    init(initiator: Bool,
         prologue: Data = Data(),
         staticPrivate: Curve25519.KeyAgreement.PrivateKey? = nil,
         remoteStatic: Data? = nil,
         ephemeralPrivate: Curve25519.KeyAgreement.PrivateKey? = nil) {
        self.initiator = initiator
        self.staticPrivate = staticPrivate
        self.remoteStatic = remoteStatic
        self.ephemeralPrivate = ephemeralPrivate
        symmetric = NoiseSymmetricState()
        symmetric.mixHash(prologue)
        // The pre-message of NK: the service's static key is known to both
        // sides before anything is sent, so both mix it in.
        if initiator {
            symmetric.mixHash(remoteStatic ?? Data())
        } else {
            symmetric.mixHash(staticPrivate?.publicKey.rawRepresentation ?? Data())
        }
    }

    /// The caller's first message, or the service's answer.
    func writeMessage(_ payload: Data = Data()) throws -> Data {
        guard messagesDone < 2, isMyTurnToWrite(messagesDone) else { throw NoiseFailure.outOfStep }
        if ephemeralPrivate == nil { ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey() }
        guard let ephemeralPrivate else { throw NoiseFailure.notAHandshakeMessage }
        let ePublic = ephemeralPrivate.publicKey.rawRepresentation
        symmetric.mixHash(ePublic)
        if initiator {
            symmetric.mixKey(try NoiseNK.agree(private: ephemeralPrivate,
                                               publicKey: remoteStatic ?? Data()))
        } else {
            symmetric.mixKey(try NoiseNK.agree(private: ephemeralPrivate,
                                               publicKey: remoteEphemeral ?? Data()))
        }
        let message = ePublic + (try symmetric.encryptAndHash(payload))
        // The turn is taken only by a message that was produced.
        messagesDone += 1
        return message
    }

    /// The other side's message, and what it carried.
    func readMessage(_ message: Data) throws -> Data {
        guard messagesDone < 2, !isMyTurnToWrite(messagesDone) else { throw NoiseFailure.outOfStep }
        guard message.count >= NoiseNK.keyLength else { throw NoiseFailure.notAHandshakeMessage }
        let ephemeral = Data(message.prefix(NoiseNK.keyLength))
        remoteEphemeral = ephemeral
        symmetric.mixHash(ephemeral)
        if initiator {
            guard let ephemeralPrivate else { throw NoiseFailure.notAHandshakeMessage }
            symmetric.mixKey(try NoiseNK.agree(private: ephemeralPrivate, publicKey: ephemeral))
        } else {
            guard let staticPrivate else { throw NoiseFailure.notAHandshakeMessage }
            symmetric.mixKey(try NoiseNK.agree(private: staticPrivate, publicKey: ephemeral))
        }
        let payload = try symmetric.decryptAndHash(Data(message.dropFirst(NoiseNK.keyLength)))
        // The turn is taken only by a message that opened; a forgery
        // leaves the handshake where it was.
        messagesDone += 1
        return payload
    }

    /// The two transport keys: the caller sends with the first. Only after
    /// both messages: keys split earlier would be keys the other side does
    /// not have.
    func split() throws -> (send: NoiseCipherState, receive: NoiseCipherState) {
        guard messagesDone == 2 else { throw NoiseFailure.outOfStep }
        let (first, second) = symmetric.split()
        return initiator ? (first, second) : (second, first)
    }
}
