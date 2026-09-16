// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The written form of the recovery key that unlocks the travelling feed
/// credentials. Pure and Foundation-only: the randomness lives at the
/// keychain door, the FORM lives here, so a fence and a test can reach it.
///
/// **Why the code is the key itself and not a short pairing code.** The
/// binding invariant is that the service must not be able to read the
/// credentials. A short code that the service brokers between two devices
/// is exactly as strong as that code, so the service could try every one of
/// them offline against the block it already holds. Twenty characters of
/// this alphabet are 100 bits, which no holder of the block can search.
/// The price is that the person carries twenty characters instead of six,
/// and the grouping below is what makes that bearable.
///
/// **The alphabet is Crockford's base32**, chosen for reading aloud and
/// retyping rather than for density: it has no `I`, `L`, `O` or `U`, so the
/// pairs that people confuse cannot both occur. `U` is out because it turns
/// up in accidental words. Reading maps the confusable shapes back (`I` and
/// `L` to `1`, `O` to `0`), so a person who types what they see is right
/// even when they see it wrong.
nonisolated enum DeviceLinkCode {
    /// The characters a code may contain, 32 of them, so each carries five
    /// bits.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Characters per code. Twenty times five bits is 100 bits of entropy.
    static let length = 20

    /// Characters per group in the written form.
    static let groupSize = 4

    /// The bytes a code carries, for the key derivation. Five characters are
    /// 25 bits, so the code is NOT a whole number of bytes; the derivation
    /// takes the normalized TEXT and not a byte reading of it, and this
    /// value exists only to say how much is in it.
    static var entropyBits: Int { length * 5 }

    /// `XXXX-XXXX-XXXX-XXXX-XXXX` from a normalized code. Nothing else
    /// changes: a code that is not the right length is handed back as it
    /// came, because inventing groups for a wrong value would hide the
    /// wrongness behind a familiar shape.
    static func grouped(_ code: String) -> String {
        guard code.count == length else { return code }
        return stride(from: 0, to: code.count, by: groupSize).map { start in
            let from = code.index(code.startIndex, offsetBy: start)
            let to = code.index(from, offsetBy: groupSize)
            return String(code[from..<to])
        }.joined(separator: "-")
    }

    /// What a person typed, read as a code, or nil when it is not one.
    ///
    /// Dashes and spaces fall away (the groups are ours, not theirs), the
    /// case does not matter, and the four confusable shapes are mapped to
    /// the digit they look like. Everything after that must be in the
    /// alphabet and the length must be exact: a code that is one character
    /// short is not a code, and accepting it would hand the failure to the
    /// decryption, which can only answer "wrong key".
    static func normalized(_ typed: String) -> String? {
        var out = ""
        for raw in typed.uppercased() {
            switch raw {
            case "-", " ", "\u{00A0}", "\t", "\n": continue
            case "I", "L": out.append("1")
            case "O": out.append("0")
            default:
                guard alphabet.contains(raw) else { return nil }
                out.append(raw)
            }
        }
        return out.count == length ? out : nil
    }

    /// A code from raw randomness. The bytes come from the door; this only
    /// says which character each one names.
    ///
    /// **Modulo bias is avoided by construction**, not by a comment: the
    /// alphabet has 32 entries and the low five bits of a byte take exactly
    /// 32 values, so every character is equally likely without a rejection
    /// loop.
    static func code(fromRandomBytes bytes: [UInt8]) -> String? {
        guard bytes.count >= length else { return nil }
        return String(bytes.prefix(length).map { alphabet[Int($0 & 0x1F)] })
    }

    /// Whether a string is already a code in normalized form.
    static func isCode(_ value: String) -> Bool {
        value.count == length && value.allSatisfy { alphabet.contains($0) }
    }
}
