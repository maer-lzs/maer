// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import CryptoKit
import CommonCrypto
import Security

/// The one-secret derivation of contract version 6, byte for byte:
///
///     M     = PBKDF2-HMAC-SHA256(NFC(password) as UTF-8, salt, rounds, 32)
///     proof = HKDF-SHA256(M, no salt, "maer sign in v1", 32)
///     feed  = HKDF-SHA256(M, no salt, "maer feed auth v2", 32)
///
/// `proof` is the only value that reaches the service; `feed` never leaves
/// the device. Nothing is trimmed: a space the person typed is part of the
/// password. Held against the published vectors (`sign-in-v6.json`).
nonisolated enum SignInDerivation {
    /// Both values of one derivation.
    struct Keys: Sendable, Equatable {
        let proof: Data
        let feed: Data

        /// How `proof` travels: standard base64 with padding.
        var proofBase64: String { proof.base64EncodedString() }
    }

    /// Why a derivation was refused or failed.
    enum Failure: Error, Equatable {
        /// Fewer rounds than the contract's floor. A service that asked for
        /// fewer would make the proof it receives cheap to guess from, and
        /// the service is exactly whom the proof must not give the password.
        case tooFewRounds(Int)
        /// More rounds than this device will stretch. `rounds` comes from
        /// the service; a number past the limit would hold the device for
        /// minutes or hours, and one past `UInt32.max` would trap.
        case tooManyRounds(Int)
        case saltNotSixteenBytes(Int)
        case stretchFailed(Int32)
    }

    /// The rounds of version 6; more are allowed, fewer are refused.
    static let minimumRounds = 600_000
    /// Ten times the contract's rounds: room for a later version to raise
    /// them, and still a wait a person can sit through. Chosen, not measured
    /// on a phone; the time of 600000 rounds on the oldest device in use is
    /// what may move it.
    static let maximumRounds = 6_000_000
    static let saltBytes = 16
    private static let signInInfo = Data("maer sign in v1".utf8)
    private static let feedInfo = Data("maer feed auth v2".utf8)

    /// A new random salt for a new password, picked by the device as the
    /// contract says; nil when the device gives no randomness, and then
    /// nothing may be derived or sent.
    static func freshSalt() -> Data? {
        var bytes = [UInt8](repeating: 0, count: saltBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    /// The password as the derivation reads it: NFC, UTF-8, untrimmed.
    static func passwordBytes(_ password: String) -> Data {
        Data(password.precomposedStringWithCanonicalMapping.utf8)
    }

    /// The whole derivation, synchronous. Stretching 600000 rounds takes a
    /// noticeable moment; callers on the main actor use `derived(...)`.
    static func derive(password: String, salt: Data, rounds: Int) throws -> Keys {
        guard rounds >= minimumRounds else { throw Failure.tooFewRounds(rounds) }
        guard rounds <= maximumRounds else { throw Failure.tooManyRounds(rounds) }
        guard salt.count == saltBytes else { throw Failure.saltNotSixteenBytes(salt.count) }
        let stretched = try stretch(passwordBytes(password), salt: salt, rounds: rounds)
        let master = SymmetricKey(data: stretched)
        return Keys(proof: expand(master, info: signInInfo), feed: expand(master, info: feedInfo))
    }

    /// The derivation off the main actor. `@concurrent` on purpose: a plain
    /// `nonisolated async` function runs on its caller's executor, and the
    /// caller is the sign-in on the main actor.
    /// `onMainThread` is the witness's probe: it hears whether the stretch
    /// ran on the main thread.
    @concurrent
    static func derived(password: String, salt: Data, rounds: Int,
                        onMainThread: (@Sendable (Bool) -> Void)? = nil) async throws -> Keys {
        onMainThread?(pthread_main_np() != 0)
        return try derive(password: password, salt: salt, rounds: rounds)
    }

    /// PBKDF2-HMAC-SHA256 to 32 bytes.
    static func stretch(_ password: Data, salt: Data, rounds: Int) throws -> Data {
        // Its own guard, because a caller could reach it without `derive`:
        // a count the C call cannot take is a refusal, never a trap.
        guard let count = UInt32(exactly: rounds), count > 0 else { throw Failure.tooManyRounds(rounds) }
        var out = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                    saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), count,
                    &out, out.count)
            }
        }
        guard status == kCCSuccess else { throw Failure.stretchFailed(status) }
        return Data(out)
    }

    /// HKDF-SHA256 without salt (RFC 5869 then uses 32 zero bytes).
    private static func expand(_ master: SymmetricKey, info: Data) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: info, outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }
}
