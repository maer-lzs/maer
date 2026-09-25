// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import CryptoKit

/// Seals the feed credentials so that the service carries them without
/// being able to read them.
///
/// **This is the invariant of the whole point, not a hardening.** Everything
/// the service carries so far gives nobody access to anything; a feed
/// password does. So the block goes over the wire sealed, and the key never
/// reaches the service and never reaches Apple.
///
/// **The envelope is JSON on purpose.** The service refuses a write it
/// cannot read as a document, which is what keeps a truncated body from
/// replacing a good one. Sealed bytes in base64 inside a JSON envelope
/// satisfy that gate without telling the service one thing about feeds.
nonisolated enum FeedAuthCrypto {
    /// The document format on the wire (`X-Maer-Format`). It stays 1: the
    /// envelope below says which key sealed it, and an older build reads a
    /// higher envelope version as `newerFormat` and leaves the block alone.
    static let format = 1
    /// Envelope 1 is sealed with the device code, envelope 2 with the
    /// account's feed key (`FeedKeyStore`), the same on every device that
    /// signed in with the password.
    static let codeEnvelope = FeedAuthRound.codeEnvelope
    static let feedEnvelope = FeedAuthRound.feedEnvelope
    private static let codeInfo = Data("maer feed auth v1".utf8)
    private static let feedInfo = Data("maer feed auth block v2".utf8)
    private static let saltBytes = 16

    /// The envelope is opened into the vocabulary of the pure side.
    typealias Opening = FeedAuthBlock.Opening

    /// Seal bytes under a recovery code (envelope 1), for a device that has
    /// no feed key yet. A fresh salt per write, so two devices with the same
    /// code still produce different keys per block and nothing about the
    /// code leaks through repetition.
    static func seal(_ plaintext: Data, code: String) -> Data? {
        seal(plaintext, version: codeEnvelope) { derive(code: code, salt: $0) }
    }

    /// Seal bytes under the account's feed key (envelope 2).
    static func seal(_ plaintext: Data, feed: Data) -> Data? {
        seal(plaintext, version: feedEnvelope) { derive(feed: feed, salt: $0) }
    }

    private static func seal(_ plaintext: Data, version: Int, key make: (Data) -> SymmetricKey?) -> Data? {
        var salt = [UInt8](repeating: 0, count: saltBytes)
        // A failure here can only mean the machine gave no randomness or
        // no key. Then NOTHING is written and the caller sees that in nil;
        // a logged reason would stand beside a value that does not exist.
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess,
              let key = make(Data(salt)),
              // bearable, because a failure writes nothing and answers nil
              let sealed = try? AES.GCM.seal(plaintext, using: key),
              let nonce = sealed.nonce.withUnsafeBytes({ Data($0) }) as Data?
        else { return nil }
        let envelope: [String: Any] = [
            "v": version,
            "kdf": "hkdf-sha256",
            "salt": Data(salt).base64EncodedString(),
            "n": nonce.base64EncodedString(),
            "c": (sealed.ciphertext + sealed.tag).base64EncodedString()
        ]
        // The envelope is numbers and base64 text, so a failure here means
        // a broken machine, not a bad input.
        // bearable, because nothing comes into being when it fails
        return try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    /// The envelope version of a block, nil when it is not an envelope.
    static func version(of envelope: Data) -> Int? {
        // bearable, because "not an envelope" is exactly what nil says
        guard let raw = try? JSONSerialization.jsonObject(with: envelope),
              let document = raw as? [String: Any] else { return nil }
        return document["v"] as? Int
    }

    /// Open an envelope with the key its version names: the code for
    /// envelope 1, the feed key for envelope 2. A missing key opens nothing,
    /// which reads the same as a key of another device.
    static func open(_ envelope: Data, code: String?, feed: Data?) -> Opening {
        // bearable, because unreadable IS the answer here and is returned below
        guard let raw = try? JSONSerialization.jsonObject(with: envelope),
              let document = raw as? [String: Any],
              let version = document["v"] as? Int else { return .unreadable }
        guard version <= feedEnvelope else { return .newerFormat(version) }
        guard let saltText = document["salt"] as? String,
              let nonceText = document["n"] as? String,
              let bodyText = document["c"] as? String,
              let salt = Data(base64Encoded: saltText),
              let nonceData = Data(base64Encoded: nonceText),
              let body = Data(base64Encoded: bodyText),
              body.count > 16
        else { return .unreadable }
        let key: SymmetricKey?
        if version == feedEnvelope {
            key = feed.flatMap { derive(feed: $0, salt: salt) }
        } else {
            key = code.flatMap { derive(code: $0, salt: salt) }
        }
        guard let key else { return .sealedForAnother }
        guard
              // bearable, because a wrong nonce gives the same finding as a broken envelope
              let nonce = try? AES.GCM.Nonce(data: nonceData)
        else { return .unreadable }
        let tag = body.suffix(16)
        let ciphertext = body.prefix(body.count - 16)
        // bearable, because a failure is EXACTLY the finding the caller needs
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              // bearable, because a wrong key and a changed block fail alike here
              let plaintext = try? AES.GCM.open(box, using: key)
        else { return .sealedForAnother }
        return .plaintext(plaintext)
    }

    /// The code is TEXT, and the derivation takes it as text.
    ///
    /// Twenty characters of the code alphabet are 100 bits but not a whole
    /// number of bytes, so a byte reading would either pad or drop and both
    /// are a way to lose entropy quietly. The salt makes the derivation
    /// per-block, the info string ties it to this purpose, and a key derived
    /// here can therefore never collide with one derived somewhere else for
    /// something else.
    private static func derive(code: String, salt: Data) -> SymmetricKey? {
        guard DeviceLinkCode.isCode(code) else { return nil }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                                      salt: salt, info: codeInfo, outputByteCount: 32)
    }

    /// The feed key is 32 bytes of key material from the one-secret
    /// derivation; each block derives its own key from it with a fresh salt
    /// and an info of its own, so no two blocks share a key and the feed key
    /// itself never seals anything directly.
    private static func derive(feed: Data, salt: Data) -> SymmetricKey? {
        guard feed.count == 32 else { return nil }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: feed),
                                      salt: salt, info: feedInfo, outputByteCount: 32)
    }
}
