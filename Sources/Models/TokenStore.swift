// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The token of a sign-in is stored and read back before it holds: what
/// the keychain holds afterwards decides, not what the write answered. A
/// keychain that refuses keeps the token before (measured at
/// `KeychainStore.save`: a failed add or update deletes nothing).
nonisolated enum TokenStore {
    /// NEW: the new token is stored. OLD: another token stands, the one
    /// before. NONE: no token stands.
    enum Outcome: Equatable, Sendable { case new, old, none }

    static func store(_ token: String, save: (String) -> Bool, read: () -> String?) -> Outcome {
        _ = save(token)
        switch read() {
        case token?: return .new
        case let other? where !other.isEmpty: return .old
        default: return .none
        }
    }
}
