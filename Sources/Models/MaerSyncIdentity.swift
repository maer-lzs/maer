// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whose data a sync state belongs to: one account on one service. The
/// service is named by the fingerprint of its key, so the same service under
/// another address (a LAN address, a name) is the same identity; the account
/// is the name the person signed in with, taken as the service takes it.
/// A service that offered no key is named by its address instead.
nonisolated struct MaerSyncIdentity: Equatable, Sendable {
    let service: String
    let owner: String

    init(service: String, owner: String) {
        self.service = service
        self.owner = owner
    }

    /// A short, stable name for keys on this device (FNV-1a over both
    /// parts). It never leaves the device and names no account in clear.
    var scope: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array("\(service)\n\(owner)".utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// The key a value of this identity is kept under.
    func keyed(_ base: String) -> String { "\(base).\(scope)" }
}
