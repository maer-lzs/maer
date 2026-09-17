// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CryptoKit
import Foundation

/// The written fingerprint of a service's static key, computed HERE from
/// the key's bytes, and never taken from what the service says about
/// itself.
///
/// The value this device holds, shows and compares is one value, and it
/// hangs on the key: whoever answers with different bytes gets a different
/// fingerprint, whatever label they send along. A label taken from the
/// answer would let somebody in the middle send their own key with the old
/// label, and the standing would say "unchanged".
///
/// Same derivation as the service prints for its operator, from the same
/// published table and not from each other: SHA-256 of the 32 bytes, the
/// first 15 bytes of that, Crockford's base32 (no I, L, O, U), 24 letters in
/// six groups of four. Two vectors computed with the service's function
/// stand in the witnesses of both repositories.
nonisolated enum ServiceKeyFingerprint {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let digestBytes = 15
    static let group = 4

    /// The fingerprint, or nil for anything that is not a 32 byte key: a
    /// shorter key means something was cut on the way, which is precisely
    /// when a fingerprint must not look fine.
    static func written(for key: Data) -> String? {
        guard key.count == 32 else { return nil }
        let digest = Data(SHA256.hash(data: key)).prefix(digestBytes)
        var bits = 0
        var held = 0
        var letters: [Character] = []
        for byte in digest {
            bits = (bits << 8) | Int(byte)
            held += 8
            while held >= 5 {
                held -= 5
                letters.append(alphabet[(bits >> held) & 0x1F])
            }
        }
        return stride(from: 0, to: letters.count, by: group)
            .map { String(letters[$0..<min($0 + group, letters.count)]) }
            .joined(separator: "-")
    }
}
