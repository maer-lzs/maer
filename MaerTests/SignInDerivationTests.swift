// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import CryptoKit
import os
@testable import Maer

/// The derivation of contract version 6 against the published vectors,
/// which the service holds byte for byte too.
struct SignInDerivationTests {
    nonisolated struct Vector: Decodable {
        let name: String
        let password_utf8_hex: String
        let salt_hex: String
        let rounds: Int
        let stretched_hex: String
        let sign_in_hex: String
        let feed_hex: String
        let proof_base64: String
    }

    nonisolated struct Vectors: Decodable { let vectors: [Vector] }

    /// The digest of `sign-in-v6.json` as the service repository holds it.
    nonisolated static let vectorsDigest = "1b796ce806b708a7f9ce07b5c06f6696395915d294d9136c00872d338c410cb9"

    nonisolated static func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SignIn/sign-in-v6.json")
    }

    nonisolated static func fixture() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: try Data(contentsOf: fixtureURL()))
    }

    @Test("Fassung 6: die Anmelde-Vektoren sind die Bytes des Dienstes")
    func vectorsAreTheServicesBytes() throws {
        let data = try Data(contentsOf: Self.fixtureURL())
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.vectorsDigest, "the vectors are copied from the service repository; a change belongs in both")
    }

    @Test("Fassung 6: Dehnung, Beweis und Feed-Schluessel gleich allen Vektoren")
    func derivationMatchesEveryVector() throws {
        let vectors = try Self.fixture().vectors
        try #require(vectors.count == 3, "the three published vectors")
        for vector in vectors {
            let password = String(decoding: NoiseNKTests.bytes(vector.password_utf8_hex), as: UTF8.self)
            let salt = NoiseNKTests.bytes(vector.salt_hex)
            let stretched = try SignInDerivation.stretch(SignInDerivation.passwordBytes(password),
                                                         salt: salt, rounds: vector.rounds)
            #expect(stretched == NoiseNKTests.bytes(vector.stretched_hex), "\(vector.name): stretched")
            let keys = try SignInDerivation.derive(password: password, salt: salt, rounds: vector.rounds)
            #expect(keys.proof == NoiseNKTests.bytes(vector.sign_in_hex), "\(vector.name): proof")
            #expect(keys.feed == NoiseNKTests.bytes(vector.feed_hex), "\(vector.name): feed")
            #expect(keys.proofBase64 == vector.proof_base64, "\(vector.name): proof as it travels")
        }
    }

    @Test("Fassung 6: zerlegt eingegeben wird zusammengesetzt abgeleitet, nichts wird getrimmt")
    func normalizationIsNFCAndNothingTrimmed() throws {
        let vectors = try Self.fixture().vectors
        let nfd = try #require(vectors.first { $0.name == "nfd input becomes nfc" })
        let typed = String(decoding: NoiseNKTests.bytes(nfd.password_utf8_hex), as: UTF8.self)
        #expect(Data(typed.utf8) != SignInDerivation.passwordBytes(typed), "the precondition: the input is not NFC")
        #expect(SignInDerivation.passwordBytes(" a ") == Data(" a ".utf8), "spaces stay")
    }

    @Test("Fassung 6: weniger als 600000 Runden und ein Salz, das nicht 16 Byte hat, werden abgewiesen")
    func weakParametersAreRefused() {
        #expect(throws: SignInDerivation.Failure.tooFewRounds(599_999)) {
            try SignInDerivation.derive(password: "zwoelf zeichen", salt: Data(count: 16), rounds: 599_999)
        }
        #expect(throws: SignInDerivation.Failure.saltNotSixteenBytes(15)) {
            try SignInDerivation.derive(password: "zwoelf zeichen", salt: Data(count: 15), rounds: 600_000)
        }
    }

    @Test("Fassung 6: zu viele Runden vom Dienst sind eine Weigerung, nie ein Absturz und nie Stunden")
    func tooManyRoundsAreRefused() throws {
        let limit = SignInDerivation.maximumRounds
        #expect(throws: SignInDerivation.Failure.tooManyRounds(limit + 1)) {
            try SignInDerivation.derive(password: "zwoelf zeichen", salt: Data(count: 16), rounds: limit + 1)
        }
        let pastUInt32 = Int(UInt32.max) + 1
        #expect(throws: SignInDerivation.Failure.tooManyRounds(pastUInt32)) {
            try SignInDerivation.derive(password: "zwoelf zeichen", salt: Data(count: 16), rounds: pastUInt32)
        }
        #expect(throws: SignInDerivation.Failure.tooManyRounds(pastUInt32), "the stretch refuses on its own") {
            try SignInDerivation.stretch(Data("zwoelf zeichen".utf8), salt: Data(count: 16), rounds: pastUInt32)
        }
        // The limit itself still stretches.
        let keys = try SignInDerivation.derive(password: "zwoelf zeichen", salt: Data(count: 16), rounds: limit)
        #expect(keys.proof.count == 32)
    }

    @Test("Fassung 6: die Dehnung laeuft nicht auf dem Hauptthread, auch wenn der Hauptakteur fragt")
    @MainActor
    func stretchRunsOffTheMainThread() async throws {
        let seen = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let vector = try #require(try Self.fixture().vectors.first)
        let keys = try await SignInDerivation.derived(
            password: String(decoding: NoiseNKTests.bytes(vector.password_utf8_hex), as: UTF8.self),
            salt: NoiseNKTests.bytes(vector.salt_hex), rounds: vector.rounds,
            onMainThread: { value in seen.withLock { $0.append(value) } })
        #expect(keys.proofBase64 == vector.proof_base64)
        #expect(seen.withLock { $0 } == [false], "the probe ran once, off the main thread")
    }
}

/// The client's rule for a new password.
struct PasswordRuleTests {
    @Test("Neues Passwort: zwoelf Zeichen wie gesehen, und nie das alte")
    func twelveCharactersAndNeverTheOld() {
        #expect(PasswordRule.check(new: "elf zeichen", current: nil) == .tooShort(missing: 1))
        #expect(PasswordRule.check(new: "zwoelf zeich", current: nil) == .acceptable)
        // Twelve letters typed with combining marks count as twelve.
        let decomposed = String(repeating: "a\u{0308}", count: 12)
        #expect(PasswordRule.check(new: decomposed, current: nil) == .acceptable)
        // Six such letters are twelve code points and still six characters.
        #expect(PasswordRule.check(new: String(repeating: "a\u{0308}", count: 6), current: nil) == .tooShort(missing: 6))
        #expect(PasswordRule.check(new: String(repeating: "\u{00E4}", count: 12),
                                   current: decomposed) == .sameAsCurrent, "the same password in another form")
        #expect(PasswordRule.check(new: "ein ganz neues passwort", current: "das alte passwort") == .acceptable)
    }
}
#endif
