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
    /// The envelope format this build writes.
    static let format = 1
    private static let info = Data("maer feed auth v1".utf8)
    private static let saltBytes = 16

    /// The envelope is opened into the vocabulary of the pure side.
    typealias Opening = FeedAuthBlock.Opening

    /// Seal bytes under a recovery code. A fresh salt per write, so two
    /// devices with the same code still produce different keys per block and
    /// nothing about the code leaks through repetition.
    static func seal(_ plaintext: Data, code: String) -> Data? {
        var salt = [UInt8](repeating: 0, count: saltBytes)
        // A failure here can only mean the machine gave no randomness or
        // no key. Then NOTHING is written and the caller sees that in nil;
        // a logged reason would stand beside a value that does not exist.
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess,
              let key = derive(code: code, salt: Data(salt)),
              // bearable, because a failure writes nothing and answers nil
              let sealed = try? AES.GCM.seal(plaintext, using: key),
              let nonce = sealed.nonce.withUnsafeBytes({ Data($0) }) as Data?
        else { return nil }
        let envelope: [String: Any] = [
            "v": format,
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

    /// Open an envelope with a recovery code.
    static func open(_ envelope: Data, code: String) -> Opening {
        // bearable, because unreadable IS the answer here and is returned below
        guard let raw = try? JSONSerialization.jsonObject(with: envelope),
              let document = raw as? [String: Any],
              let version = document["v"] as? Int else { return .unreadable }
        guard version <= format else { return .newerFormat(version) }
        guard let saltText = document["salt"] as? String,
              let nonceText = document["n"] as? String,
              let bodyText = document["c"] as? String,
              let salt = Data(base64Encoded: saltText),
              let nonceData = Data(base64Encoded: nonceText),
              let body = Data(base64Encoded: bodyText),
              body.count > 16,
              let key = derive(code: code, salt: salt),
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
                                      salt: salt, info: info, outputByteCount: 32)
    }
}
