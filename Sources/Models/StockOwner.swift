// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whose the device's own stock is: the identity (`MaerSyncIdentity.scope`)
/// the local listening stands, playlists, choices and feed access belong
/// to. Kept on the device, so a change of account counts across a sign-out
/// and a restart: A, signed out, then B is a switch; A, signed out, then A
/// again is none. The first sign-in of a device without an owner takes the
/// stock over, as it always did.
nonisolated enum StockOwner {
    static let key = "maerSyncStockOwner"

    enum Change: Equatable {
        /// Nothing changes hands: signed out, or the owner signed in again.
        case none
        /// The first sign-in of the device: its stock becomes this account's.
        case first(String)
        /// Another account than the stock's owner.
        case switched(from: String, to: String)

        var isSwitch: Bool {
            if case .switched = self { return true }
            return false
        }
    }

    /// `owner`: whose the stock is; `now`: the identity signed in, nil when
    /// signed out. Signing out keeps the owner.
    static func change(owner: String?, now: String?) -> Change {
        guard let now else { return .none }
        guard let owner else { return .first(now) }
        return owner == now ? .none : .switched(from: owner, to: now)
    }

    static func owner(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: key)
    }

    static func setOwner(_ scope: String, in defaults: UserDefaults) {
        defaults.set(scope, forKey: key)
    }
}
