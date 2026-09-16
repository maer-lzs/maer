// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The feed credentials as ONE block, in the shape that gets encrypted.
///
/// Pure and Foundation-only, so the shape can be read without a key and
/// without a device: the encryption sits a layer above and knows nothing
/// about feeds, which is what keeps the service from understanding what it
/// carries.
///
/// **The unit is the whole block**, not one entry per feed. A carrier that
/// spoke single feeds would have to tell a credential the person deleted
/// from one this device has never seen, and it cannot: both look like
/// "absent" from here.
nonisolated enum FeedAuthBlock {
    /// What one feed needs. The pair travels together or not at all.
    struct Credentials: Equatable, Sendable {
        let user: String
        let password: String
    }

    /// A credential with the moment this side last wrote it. The moment is
    /// what lets two devices decide without asking anyone, and it is the
    /// only field here that is not a secret.
    struct Entry: Equatable, Sendable {
        let credentials: FeedAuthBlock.Credentials
        /// Epoch milliseconds. Zero means "held, moment unknown", which is
        /// what a credential entered before this existed looks like.
        let at: Double
    }

    /// The format this build writes.
    static let format = 1

    /// What came back from a block, and the two answers that are NOT a set
    /// of entries are the point of this type.
    enum Reading: Equatable {
        /// Readable, and these are the entries. May legitimately be empty.
        case entries([String: Entry])
        /// A newer build wrote this. We can neither read nor replace it:
        /// writing would throw away what we cannot see.
        case newerFormat(Int)
        /// Not a block at all, or damaged. Same consequence, different
        /// cause, and the two are kept apart because only one of them is a
        /// reason to look at the other device.
        case unreadable
    }

    /// The block as bytes, before encryption. Sorted, so the same state
    /// gives the same bytes and a difference means a real change.
    static func encode(_ entries: [String: Entry]) -> Data? {
        var out: [String: Any] = [:]
        for (key, value) in entries {
            out[key] = ["u": value.credentials.user,
                        "p": value.credentials.password,
                        "t": value.at]
        }
        let document: [String: Any] = ["v": format, "e": out]
        return try? JSONSerialization.data(withJSONObject: document,
                                           options: [.sortedKeys])
    }

    /// Bytes back to entries, or the reason why not.
    ///
    /// **Tolerant about what it does not know, strict about what it needs.**
    /// An unknown field at the top is ignored, because a later build may add
    /// one and this one must not choke. An entry without both halves of the
    /// pair is skipped rather than half-adopted: half a credential is an
    /// authorization that fails, and a failing authorization looks to
    /// everything above like a wrong password. A missing moment is NOT a
    /// reason to skip; it reads as zero and loses every tie, which is what
    /// an entry from before the moment existed should do.
    static func decode(_ data: Data) -> Reading {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let document = raw as? [String: Any],
              let version = document["v"] as? Int else { return .unreadable }
        guard version <= format else { return .newerFormat(version) }
        guard let entries = document["e"] as? [String: Any] else { return .unreadable }
        var out: [String: Entry] = [:]
        for (key, value) in entries {
            guard let pair = value as? [String: Any],
                  let user = pair["u"] as? String,
                  let password = pair["p"] as? String else { continue }
            let at = (pair["t"] as? Double) ?? 0
            out[key] = Entry(credentials: Credentials(user: user, password: password), at: at)
        }
        return .entries(out)
    }
}
