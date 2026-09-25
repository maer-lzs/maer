// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The device code that sealed the travelling feed credentials before the
/// account's feed key did. No code is created or taken over any more: a
/// device keeps the one it has until its own block sealed with the feed key
/// stands at the service, and then forgets it (`FeedAuthSync`). Until then
/// it opens the blocks other devices sealed with the same code.
///
/// **It never travelled through Apple**, and it still lies only in the
/// device-local keychain; a fence holds that the reise parameter is never
/// passed from this file.
nonisolated enum DeviceLinkCodeStore {
    static let keychainKey = "deviceLinkCode"

    /// The code this device holds, in its written form, or nil.
    static func current() -> String? {
        guard let stored = KeychainStore.load(forKey: keychainKey),
              DeviceLinkCode.isCode(stored) else { return nil }
        return stored
    }

    /// Forget the code: once the own block sealed with the feed key stands,
    /// and on the path that disconnects the service on purpose. The
    /// credentials themselves are not touched.
    static func forget() {
        KeychainStore.delete(forKey: keychainKey)
        Logger.library.notice("feed auth key: device code forgotten")
    }
}
