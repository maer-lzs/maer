// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

extension Artwork {
    /// The one directory of remembered picture answers behind the door:
    /// for a question ("the channel picture of this feed", "the logo of
    /// this station") the answer once found, or the fact that a clean
    /// search found none, with the moment it was made and the moment it
    /// stops counting. Before, each chain kept its own dictionary in its
    /// own key with its own expiry rule; now one place, one rule, and the
    /// door answers "there is none until …".
    ///
    /// Keys are namespaced by the asker (`feed|<address>`, `radio|<id>`).
    /// The value is the asker's fact as text (an address, a file name);
    /// the directory does not interpret it. A negative may carry the
    /// stamp of the judgement it was made under (`under`): when the asker's
    /// thresholds change, its old "no" is stale and re-asked, while a "yes"
    /// stays a yes under any rule.
    nonisolated enum Memo {
        static let key = "artworkMemo"

        struct Entry: Codable, Equatable {
            /// The fact found; nil is a clean "none".
            var value: String?
            /// Epoch seconds of the search.
            var resolvedAt: Double
            /// Epoch seconds until which the entry counts; nil never expires.
            var until: Double?
            /// The judgement stamp a negative was made under.
            var under: String?
        }

        enum Answer: Equatable {
            case found(String)
            case missing
        }

        // MARK: - Asking

        /// The valid answer for a key, else nil: unknown, expired, or a
        /// negative made under another stamp.
        static func remembered(_ key: String, under stamp: String? = nil,
                               now: Double = Date().timeIntervalSince1970,
                               defaults: UserDefaults = AppStorageKeys.store) -> Answer? {
            guard let entry = load(defaults: defaults)[key] else { return nil }
            return answer(entry, under: stamp, now: now)
        }

        /// Every valid answer under a namespace, keyed without the prefix.
        /// One decode for a whole session cache.
        static func answers(prefix: String, under stamp: String? = nil,
                            now: Double = Date().timeIntervalSince1970,
                            defaults: UserDefaults = AppStorageKeys.store) -> [String: Answer] {
            var out: [String: Answer] = [:]
            for (key, entry) in load(defaults: defaults) where key.hasPrefix(prefix) {
                guard let answer = answer(entry, under: stamp, now: now) else { continue }
                out[String(key.dropFirst(prefix.count))] = answer
            }
            return out
        }

        /// Every stored entry under a namespace, valid or not, keyed
        /// without the prefix. For a diagnosis that reports what is written
        /// down, including how old it is.
        static func entries(prefix: String,
                            defaults: UserDefaults = AppStorageKeys.store) -> [String: Entry] {
            var out: [String: Entry] = [:]
            for (key, entry) in load(defaults: defaults) where key.hasPrefix(prefix) {
                out[String(key.dropFirst(prefix.count))] = entry
            }
            return out
        }

        private static func answer(_ entry: Entry, under stamp: String?, now: Double) -> Answer? {
            if let until = entry.until, now > until { return nil }
            if let value = entry.value { return .found(value) }
            if let stamp, entry.under != stamp { return nil }
            return .missing
        }

        // MARK: - Writing

        /// Writes an answer down. `value` nil is "there is none until
        /// `until`"; `until` nil never expires. Expired entries of every
        /// namespace go with the write, so the directory cannot only grow.
        static func remember(_ key: String, value: String?, until: Double?, under stamp: String? = nil,
                             now: Double = Date().timeIntervalSince1970,
                             defaults: UserDefaults = AppStorageKeys.store) {
            var stored = load(defaults: defaults).filter { $0.value.until.map { $0 >= now } ?? true }
            stored[key] = Entry(value: value, resolvedAt: now, until: until, under: stamp)
            save(stored, defaults: defaults)
        }

        /// Drops an answer so the question is open again. Never books a
        /// negative: clearing re-opens, it does not decide.
        @discardableResult
        static func forget(_ key: String, defaults: UserDefaults = AppStorageKeys.store) -> Bool {
            var stored = load(defaults: defaults)
            guard stored.removeValue(forKey: key) != nil else { return false }
            save(stored, defaults: defaults)
            return true
        }

        // MARK: - The one dictionary

        private static func load(defaults: UserDefaults) -> [String: Entry] {
            guard let data = defaults.data(forKey: key) else { return [:] }
            // bearable, because an unreadable directory only costs notes; every question is then asked again
            return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }

        private static func save(_ entries: [String: Entry], defaults: UserDefaults) {
            // bearable, because a Codable dictionary of text and numbers always encodes; a failure would only leave the old state standing
            guard let data = try? JSONEncoder().encode(entries) else { return }
            defaults.set(data, forKey: key)
        }
    }
}
