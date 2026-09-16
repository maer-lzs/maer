// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Per-feed HTTP Basic auth for private/premium podcasts (user/password in the
/// keychain, bound to the stable `feedKey`). Provides the `Authorization`
/// header for feed fetch, streaming and download. Nonisolated. Usable from the
/// parser (background), the providers and the player.
nonisolated enum PodcastFeedAuth {
    private static func key(_ feedKey: String) -> String { "\(prefix)\(feedKey)" }

    static func credentials(feedKey: String) -> (user: String, password: String)? {
        guard let raw = KeychainStore.load(forKey: key(feedKey)),
              let sep = raw.firstIndex(of: "\n") else { return nil }
        return (String(raw[..<sep]), String(raw[raw.index(after: sep)...]))
    }

    /// Feed credentials follow the iCloud KEYCHAIN when the user's
    /// iCloud channel is on. This is the class gpodder cannot carry (a URL
    /// without its credentials would be half a state, and the token class
    /// travels the other way). Off = exactly today's behaviour, device-local.
    static func set(feedKey: String, user: String, password: String,
                    now: Date = Date(), defaults: UserDefaults = .standard) {
        if user.isEmpty && password.isEmpty {
            KeychainStore.delete(forKey: key(feedKey))
        } else {
            write(feedKey: feedKey, user: user, password: password)
        }
        // The moment, beside the secret and never inside it. Two devices
        // decide per feed by it, and it is the only field of this class that
        // may be read by anything that is not the keychain.
        stamp(feedKey: feedKey, at: user.isEmpty && password.isEmpty ? nil : now,
              defaults: defaults)
    }

    // MARK: - The whole class, for the carrier

    /// Where the moments live. Not a secret, so not in the keychain: a
    /// timestamp in the keychain would be a second item per feed with the
    /// same travel question and no reason to have it.
    static let stampsKey = "feedAuthStamps"

    /// Every credential this device holds, with its moment.
    ///
    /// **Nil when the keychain could not be listed**, which a caller must
    /// keep apart from "this person has none": writing a block from the
    /// second reading would delete every credential the other devices hold.
    static func all(defaults: UserDefaults = .standard) -> [String: FeedAuthBlock.Entry]? {
        guard let items = KeychainStore.values(withPrefix: prefix) else { return nil }
        let stamps = (defaults.dictionary(forKey: stampsKey) as? [String: Double]) ?? [:]
        var out: [String: FeedAuthBlock.Entry] = [:]
        for (account, raw) in items {
            let feedKey = String(account.dropFirst(prefix.count))
            guard let sep = raw.firstIndex(of: "\n") else { continue }
            let pair = FeedAuthBlock.Credentials(user: String(raw[..<sep]),
                                                 password: String(raw[raw.index(after: sep)...]))
            out[feedKey] = FeedAuthBlock.Entry(credentials: pair, at: stamps[feedKey] ?? 0)
        }
        return out
    }

    /// Apply a merged state. Writes what differs and leaves the rest alone.
    ///
    /// **It never deletes.** The merge rule says a removal does not travel
    /// in this format, so nothing that arrives can be a reason to drop a
    /// credential; a person removes one on the device they are holding.
    static func apply(_ entries: [String: FeedAuthBlock.Entry],
                      defaults: UserDefaults = .standard) {
        let mine = all(defaults: defaults) ?? [:]
        for (feedKey, entry) in entries where mine[feedKey]?.credentials != entry.credentials {
            write(feedKey: feedKey, user: entry.credentials.user,
                  password: entry.credentials.password)
            stamp(feedKey: feedKey, atMs: entry.at, defaults: defaults)
        }
    }

    private static let prefix = "feedAuth."

    /// The ONE place in this file that names the Apple channel. Both the
    /// user's own edit and an adopted block go through here, so the question
    /// "does this class still follow the iCloud keychain" has one answer and
    /// not two that can drift.
    private static func write(feedKey: String, user: String, password: String) {
        KeychainStore.save("\(user)\n\(password)", forKey: key(feedKey),
                           synchronizable: AppStorageKeys.podcastICloudSyncEnabled)
    }

    private static func stamp(feedKey: String, at moment: Date?,
                              defaults: UserDefaults) {
        stamp(feedKey: feedKey,
              atMs: moment.map { $0.timeIntervalSince1970 * 1000 },
              defaults: defaults)
    }

    private static func stamp(feedKey: String, atMs: Double?,
                              defaults: UserDefaults) {
        var stamps = (defaults.dictionary(forKey: stampsKey) as? [String: Double]) ?? [:]
        if let atMs { stamps[feedKey] = atMs } else { stamps[feedKey] = nil }
        defaults.set(stamps, forKey: stampsKey)
    }

    /// Remove stored credentials (tests + explicit disconnects).
    static func remove(feedKey: String) {
        KeychainStore.delete(forKey: key(feedKey))
    }

    static func hasCredentials(feedKey: String) -> Bool {
        credentials(feedKey: feedKey) != nil
    }

    /// `Authorization: Basic …` for a feed (empty when there are no credentials).
    static func authHeader(feedKey: String) -> [String: String] {
        guard let c = credentials(feedKey: feedKey) else { return [:] }
        let token = Data("\(c.user):\(c.password)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }

    /// Auth header from an `rss:<feedKey>:<guid>` item id (empty otherwise).
    static func authHeader(forItemId id: String) -> [String: String] {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "rss" else { return [:] }
        return authHeader(feedKey: String(parts[1]))
    }
}
