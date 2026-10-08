// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

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

    /// Feed credentials travel over exactly one way: the service when a
    /// service access is stored, else the iCloud KEYCHAIN when the switch is
    /// on, else nowhere (`travelsOverApple`). This is the class gpodder
    /// cannot carry (a URL without its credentials would be half a state,
    /// and the token class travels the other way).
    /// `writing` is the keychain write, handed in so a witness can let it
    /// fail; the app passes nothing.
    static func set(feedKey: String, user: String, password: String,
                    now: Date = Date(), defaults: UserDefaults = .standard,
                    writing: (String, String, String) -> Bool = write,
                    deleting: (String) -> Void = { KeychainStore.delete(forKey: $0) }) {
        if user.isEmpty && password.isEmpty {
            // The person removes the sign-in of the account signed in now,
            // the live item alone. What rests belongs to another account,
            // whose shelf still names it: removing it would hold that
            // account's hand-over for ever (and the account's own copies
            // are cleared once they are live again, `clearRest`).
            deleting(key(feedKey))
            stamp(feedKey: feedKey, at: nil, defaults: defaults)
            return
        }
        // The moment, beside the secret and never inside it. Two devices
        // decide per feed by it, and it is the only field of this class that
        // may be read by anything that is not the keychain. It is booked
        // only for a write that landed: a moment without its secret would
        // let the old secret win every merge from now on.
        guard writing(feedKey, user, password) else { return }
        stamp(feedKey: feedKey, at: now, defaults: defaults)
    }

    // MARK: - The whole class, for the carrier

    /// Where the moments live. Not a secret, so not in the keychain: a
    /// timestamp in the keychain would be a second item per feed with the
    /// same travel question and no reason to have it.
    static let stampsKey = "feedAuthStamps"

    /// When this feed's sign-in was last written on this device (ms), nil
    /// when it has none. Only the moment, never the secret.
    static func moment(feedKey: String, defaults: UserDefaults = .standard) -> Double? {
        ((defaults.dictionary(forKey: stampsKey) as? [String: Double]) ?? [:])[feedKey]
    }

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
    ///
    /// `mine` is what this device holds, as the caller listed it for the
    /// round. **Nil means the keychain could not be listed, and then nothing
    /// is done:** an apply that does not know its own stock would write
    /// every entry, and each write that failed on the locked keychain would
    /// still have been stamped with the newer moment, so the old secret
    /// would win every merge from then on. A moment is booked only for a
    /// write that landed. `writing` is the keychain write, handed in so a
    /// witness can let it fail; the runner passes nothing.
    static func apply(_ entries: [String: FeedAuthBlock.Entry],
                      mine: [String: FeedAuthBlock.Entry]?,
                      defaults: UserDefaults = .standard,
                      writing: (String, String, String) -> Bool = write) {
        guard let mine else { return }
        for (feedKey, entry) in entries where mine[feedKey]?.credentials != entry.credentials {
            guard writing(feedKey, entry.credentials.user, entry.credentials.password) else { continue }
            stamp(feedKey: feedKey, atMs: entry.at, defaults: defaults)
        }
    }

    private static let prefix = "feedAuth."

    /// The way of the moment, the same question the five carrier factories
    /// ask: with a service access nothing of this class travels over Apple
    /// (the service replaces Apple, and a credential that went both ways
    /// would sit sealed with the service AND in Apple's iCloud keychain);
    /// without one the switch decides, on for the iCloud keychain, off for
    /// this device alone. Pure, so the choice has a witness; the app passes
    /// nothing.
    static func travelsOverApple(syncEnabled: Bool = AppStorageKeys.podcastICloudSyncEnabled,
                                 serviceAccess: Bool = MaerSyncAccess.stored() != nil) -> Bool {
        syncEnabled && !serviceAccess
    }

    /// The ONE place in this file that names the Apple channel. Both the
    /// user's own edit and an adopted block go through here, so the question
    /// "which way does this class travel" has one answer and not two that
    /// can drift. Says whether the write landed.
    private static func write(feedKey: String, user: String, password: String) -> Bool {
        save(key(feedKey), "\(user)\n\(password)", travelsOverApple())
    }

    /// The one keychain write of this class: name, value and place. The
    /// live item and the resting one go through it, so both carry the same
    /// attributes (`KeychainStore.save`'s accessibility, the place the way of
    /// the moment gives).
    static func save(_ account: String, _ value: String, _ synchronizable: Bool) -> Bool {
        KeychainStore.save(value, forKey: account, synchronizable: synchronizable)
    }

    // MARK: - The owner of the credentials

    /// Where the credentials of an account that no longer owns the device
    /// rest: in the keychain, under a name per account. The name carries
    /// the account's short scope (a hash) and the feed key (a hash), never
    /// an address or a mail; the value is the same pair as the live item.
    private static let restPrefix = "feedAuthRest."
    private static func restKey(_ scope: String, _ feedKey: String) -> String { "\(restPrefix)\(scope).\(feedKey)" }

    /// Lays the credentials down for `scope`, each under its resting name,
    /// on this device only (a resting credential never travels, whatever way
    /// the live ones take), and reads every one back. False when one did not
    /// land as written: then nothing may be replaced.
    static func rest(_ entries: [String: FeedAuthBlock.Entry], for scope: String,
                     saving: (String, String, Bool) -> Bool = save,
                     loading: (String) -> String? = KeychainStore.load(forKey:)) -> Bool {
        for (feedKey, entry) in entries {
            let value = "\(entry.credentials.user)\n\(entry.credentials.password)"
            let account = restKey(scope, feedKey)
            guard saving(account, value, false), loading(account) == value else { return false }
        }
        return true
    }

    /// What rests for an account, as the keychain gave it: the credentials
    /// read, and the names of those that are not there at all.
    struct Rested: Equatable {
        var credentials: [String: FeedAuthBlock.Credentials] = [:]
        var missing: [String] = []
    }

    /// The resting credentials of `scope` for `feedKeys`; nil when one of
    /// them cannot be read (the device locked since it started), so the
    /// hand-over holds. One that is not there is named in `missing`: holding
    /// for it would hold for ever.
    static func rested(_ feedKeys: [String], of scope: String,
                       reading: (String) -> KeychainRead = KeychainStore.read(forKey:)) -> Rested? {
        var out = Rested()
        for feedKey in feedKeys {
            switch reading(restKey(scope, feedKey)) {
            case .unreadable:
                return nil
            case .missing, .undecodable:
                // Bytes that do not decode are no credentials, and holding
                // for them would hold for ever, as for one not there.
                out.missing.append(feedKey)
            case .value(let raw):
                guard let sep = raw.firstIndex(of: "\n") else { out.missing.append(feedKey); continue }
                out.credentials[feedKey] = FeedAuthBlock.Credentials(user: String(raw[..<sep]),
                                                                     password: String(raw[raw.index(after: sep)...]))
            }
        }
        return out
    }

    /// The resting copies of `scope` for `feedKeys` leave once its own
    /// credentials are live again and the shelf says the replacement
    /// landed: a copy kept beyond that would be a second secret on the
    /// device that nothing uses.
    static func clearRest(of scope: String, feedKeys: [String],
                          deleting: (String) -> Void = { KeychainStore.delete(forKey: $0) }) {
        for feedKey in feedKeys { deleting(restKey(scope, feedKey)) }
    }

    /// THE SECOND removal beside the person's own (`set` with nothing,
    /// `remove`): another account owns the device. Its credentials replace
    /// the live ones, each read back, and only then the live items of the
    /// account before leave (`leaving`), which rest under its name already.
    /// False when one did not land; the next round tries again. The reads
    /// back tell "not there" from "not readable", as `rested` does.
    static func replaceForNewOwner(with incoming: [String: FeedAuthBlock.Entry], leaving: Set<String>,
                                   defaults: UserDefaults = .standard,
                                   saving: (String, String, Bool) -> Bool = save,
                                   reading: (String) -> KeychainRead = KeychainStore.read(forKey:),
                                   deleting: (String) -> Void = { KeychainStore.delete(forKey: $0) }) -> Bool {
        for (feedKey, entry) in incoming {
            let value = "\(entry.credentials.user)\n\(entry.credentials.password)"
            guard saving(key(feedKey), value, travelsOverApple()), reading(key(feedKey)) == .value(value) else { return false }
            stamp(feedKey: feedKey, atMs: entry.at, defaults: defaults)
        }
        for feedKey in leaving where incoming[feedKey] == nil {
            deleting(key(feedKey))
            // Read back like every write: a credential of the account before
            // that stayed would be sealed for this one, and one that cannot
            // be read may still be there. Only "not there" has left.
            guard reading(key(feedKey)) == .missing else {
                Logger.library.notice("FEEDAUTH removal not read back as gone")
                return false
            }
            stamp(feedKey: feedKey, atMs: nil, defaults: defaults)
        }
        return true
    }

    /// Every credential written again with the way of the moment. Called
    /// where the service access is stored, where it is removed, and where
    /// the switch flips, so no twin stays behind on the way that is no
    /// longer taken (the save puts the item at its new place before it
    /// clears the other world, so a failed write leaves the old item
    /// standing and `failed` counts an item that stayed, never one that is
    /// lost). The moments stay untouched: the secret is the same, only its
    /// place moved. Nil from the listing means the keychain could not be
    /// read, and then nothing is done; the next occasion tries again.
    @discardableResult
    static func rewriteAll(by caller: String,
                           entries: [String: String]? = KeychainStore.values(withPrefix: prefix),
                           writing: (String, String, String) -> Bool = write) -> (rewritten: Int, failed: Int) {
        guard let entries else {
            Logger.library.error("FEEDAUTH rewrite by=\(caller, privacy: .public): the keychain could not be listed, nothing rewritten")
            return (0, 0)
        }
        var rewritten = 0, failed = 0
        for (account, raw) in entries {
            guard let sep = raw.firstIndex(of: "\n") else { continue }
            let feedKey = String(account.dropFirst(prefix.count))
            if writing(feedKey, String(raw[..<sep]), String(raw[raw.index(after: sep)...])) { rewritten += 1 } else { failed += 1 }
        }
        Logger.library.notice("FEEDAUTH rewrite by=\(caller, privacy: .public) apple=\(travelsOverApple()) rewritten=\(rewritten) failed=\(failed)")
        return (rewritten, failed)
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
