// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The recovery key for the travelling feed credentials: where it comes
/// from, where it lies, and how a second device takes it over.
///
/// **It never travels through Apple.** That is the invariant this whole
/// point stands on: a key in the iCloud keychain would not replace Apple, it
/// would put a layer in front of it. So every write here goes to the
/// device-local keychain, and a fence holds that the reise parameter is
/// never passed from this file.
///
/// **It comes into being without a hurdle.** `ensure()` runs where the
/// service is set up; the person gets a key by setting up, not by agreeing
/// to a dialogue about one. Whoever wants to see it later finds it in the
/// settings.
nonisolated enum DeviceLinkCodeStore {
    static let keychainKey = "deviceLinkCode"

    /// The key this device holds, in its written form, or nil.
    static func current() -> String? {
        guard let stored = KeychainStore.load(forKey: keychainKey),
              DeviceLinkCode.isCode(stored) else { return nil }
        return stored
    }

    /// The key this device holds, creating one if there is none. Returns nil
    /// only when the system refused to produce randomness, which is a reason
    /// to carry nothing rather than to carry something guessable.
    @discardableResult
    static func ensure() -> String? {
        if let existing = current() { return existing }
        guard let fresh = generate() else {
            Logger.library.error("feed auth key: the system gave no randomness, no key created")
            return nil
        }
        KeychainStore.save(fresh, forKey: keychainKey)
        Logger.library.log("feed auth key: created")
        return fresh
    }

    /// Take over the key of another device. The caller has read it from what
    /// a person typed; this decides whether it is a code and stores it.
    ///
    /// **An existing key is overwritten on purpose.** Someone who enters a
    /// key is saying "this device belongs to that account"; keeping the old
    /// one would leave the device unable to read the block it is about to
    /// receive, and the old key protects nothing this device still needs.
    @discardableResult
    static func adopt(typed: String) -> Bool {
        guard let code = DeviceLinkCode.normalized(typed) else { return false }
        KeychainStore.save(code, forKey: keychainKey)
        Logger.library.log("feed auth key: adopted from a typed code")
        return true
    }

    /// Forget the key. Only for the path that disconnects the service on
    /// purpose; the credentials themselves are not touched, they stay on
    /// this device as they were before any of this existed.
    static func forget() {
        KeychainStore.delete(forKey: keychainKey)
    }

    /// Randomness from the system, generously. The code builder throws away
    /// the bytes that would bias the alphabet, so it needs MORE bytes than
    /// the code has characters and says so by answering nil when it runs
    /// out; four times the length leaves that practically impossible while
    /// still being one call.
    ///
    /// `SecRandomCopyBytes` is the only source used. A fallback to a weaker
    /// one would make the strong case indistinguishable from the weak one
    /// for everyone looking at the result.
    private static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: DeviceLinkCode.length * 4)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { return nil }
        return DeviceLinkCode.code(fromRandomBytes: bytes)
    }
}
