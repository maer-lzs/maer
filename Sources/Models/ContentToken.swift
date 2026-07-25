// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure content-identity token for change detection (#51/W1, class B).
/// Convention: never detect content changes via `count` — same count with
/// swapped content (a replaced subscription) must produce a DIFFERENT token.
enum ContentToken {
    /// Order-insensitive identity of a string collection: XOR of per-element
    /// FNV-1a hashes. Deterministic across processes (no `Hasher` seed), so
    /// it is testable; order-insensitive so callers can feed sets or arrays
    /// whose ordering is incidental.
    nonisolated static func of(_ elements: some Sequence<String>) -> UInt64 {
        var acc: UInt64 = 0
        for element in elements {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in element.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
            acc ^= hash
        }
        return acc
    }
}
