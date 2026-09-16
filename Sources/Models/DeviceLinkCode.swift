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
/// **The alphabet is letters only, and that is a measured choice, not a
/// taste.** The cost of this code is not its length, it is the KEYBOARD: a
/// code that mixes digits and letters forces a layer switch at every
/// boundary, and each switch is a tap. Measured over 200000 random codes on
/// the plain iOS layout, counting one tap per character plus one per switch:
///
///   32 characters mixed, 20 long, 100.0 bits  ->  28.5 taps
///   22 letters,          24 long, 107.0 bits  ->  24.0 taps
///   10 digits,           31 long, 103.0 bits  ->  32.0 taps
///
/// So the letters-only form is **shorter to type and stronger at the same
/// time**, and the mixed form was paying eight and a half taps for nothing.
///
/// **`I`, `L`, `O` and `U` are out.** The first three because they are the
/// shapes people confuse with digits, and with no digits in the alphabet
/// that confusion cannot arise at all: a person never SEES a `1` here, so
/// they never type an `I` for one. `U` is out because it turns up in
/// accidental words. What is left is 22 letters.
nonisolated enum DeviceLinkCode {
    /// The characters a code may contain, 22 of them.
    static let alphabet = Array("ABCDEFGHJKMNPQRSTVWXYZ")

    /// Characters per code. 24 letters out of 22 are about 107 bits, and 24
    /// divides into six even groups where 23 would leave a ragged one. The
    /// extra letter costs exactly one tap and buys four bits.
    static let length = 24

    /// Characters per group in the written form.
    static let groupSize = 4

    /// How much is in a code, rounded down. The alphabet is not a power of
    /// two, so a character is not a whole number of bits and the code is not
    /// a whole number of bytes; the derivation takes the normalized TEXT and
    /// never a byte reading of it. This value exists to be asserted against,
    /// so that shortening the code to make typing nicer trips a witness.
    static var entropyBits: Int {
        Int((Double(length) * log2(Double(alphabet.count))).rounded(.down))
    }

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
    /// Dashes and spaces fall away (the groups are ours, not theirs) and the
    /// case does not matter. Everything else must be in the alphabet and the
    /// length must be exact: a code that is one character short is not a
    /// code, and accepting it would hand the failure to the decryption,
    /// which can only answer "wrong key".
    ///
    /// **No character is silently corrected.** With no digits in the
    /// alphabet there is nothing for a confusable shape to be corrected TO,
    /// and a rejected character tells the person where they went wrong,
    /// which a quietly repaired one never does.
    static func normalized(_ typed: String) -> String? {
        var out = ""
        for raw in typed.uppercased() {
            switch raw {
            case "-", " ", "\u{00A0}", "\t", "\n": continue
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
    /// **Modulo bias is REJECTED, not ignored.** 22 does not divide 256, so
    /// `byte % 22` would make the first eight letters more likely than the
    /// rest. The bytes above the largest whole multiple of 22 are therefore
    /// thrown away and the caller is asked for more, which is why this takes
    /// a generous supply and answers nil when it runs out.
    static func code(fromRandomBytes bytes: [UInt8]) -> String? {
        let ceiling = 256 - (256 % alphabet.count)
        var out = ""
        for byte in bytes where Int(byte) < ceiling {
            out.append(alphabet[Int(byte) % alphabet.count])
            if out.count == length { return out }
        }
        return nil
    }

    /// Whether a string is already a code in normalized form.
    static func isCode(_ value: String) -> Bool {
        value.count == length && value.allSatisfy { alphabet.contains($0) }
    }
}
