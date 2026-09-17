// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What to do about the static key a service just offered, against the one
/// this device is holding on to.
///
/// Pure and Foundation-only, so the three answers can be driven at their
/// edges without a keychain, a network or a service. The holding itself is
/// somewhere else; this is only the decision, and the decision is the part
/// that must never be got wrong quietly.
nonisolated enum ServiceKeyTrust {
    /// Three answers, and the middle one is the whole point.
    nonisolated enum Standing: Equatable {
        /// Nothing is held yet. This is the first meeting, and the chosen
        /// migration says: trust it and hold on. **Over a plain connection
        /// somebody in the middle can be the one trusted here**, and that is
        /// not hidden anywhere: it is the price of letting people run a
        /// service without a certificate, which is the whole point of this
        /// product.
        case first
        /// The same key as last time. Nothing happens, and nothing is said:
        /// this is every ordinary connection.
        case unchanged
        /// A DIFFERENT key. Never silently accepted, never silently
        /// refused: somebody has to be told, and somebody has to decide.
        /// It can be a new server, a restored backup, or the one case this
        /// whole construction exists for.
        case changed(held: String, offered: String)
    }

    /// The standing of an offered fingerprint against the held one.
    ///
    /// Compared as written fingerprints, and the written form is COMPUTED by
    /// this device from the key's bytes (`ServiceKeyFingerprint`), never
    /// taken from the answer. So there is one value: it hangs on the key,
    /// it is what is held, and it is what a person reads and compares with
    /// the service's own printout.
    static func standing(held: String?, offered: String) -> Standing {
        guard let held, !held.isEmpty else { return .first }
        return held == offered ? .unchanged : .changed(held: held, offered: offered)
    }
}
