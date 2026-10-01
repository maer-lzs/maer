// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// When a subscribed feed's refusal counts as lasting: three times and 24
/// hours. One 401 or 403 says nothing: a
/// server has a bad minute, a token is being rotated. Three refreshes in a
/// row that are refused, with at least a day between the first and the
/// latest, say the access is gone, and only then does the show say so.
///
/// Per feed, on this device: every device measures for itself, nothing
/// here travels. A success clears the record; an answer that is neither a
/// success nor a refusal (a timeout, a 500, a 404) leaves it as it is,
/// because it says nothing about the access.
nonisolated enum FeedRefusal {
    struct Record: Equatable, Sendable {
        /// Refusals in a row.
        var count: Int
        /// Epoch seconds of the first refusal of this row.
        var firstAt: Double
        /// Epoch seconds of the latest refusal.
        var lastAt: Double
        /// The status of the latest refusal, for the log line.
        var status: Int
    }

    static let attempts = 3
    static let span: Double = 24 * 60 * 60

    /// What one refresh answer does to a feed's record.
    enum Answer: Equatable, Sendable {
        case success
        case refused(status: Int)
        /// Neither: says nothing about the access.
        case other
    }

    /// The reading of a status through the one table of meanings: only
    /// what means "sign in" is a refusal.
    static func answer(status: Int) -> Answer {
        StatusMeaning.from(status: status) == .signIn ? .refused(status: status) : .other
    }

    static func next(_ record: Record?, _ answer: Answer, now: Double) -> Record? {
        switch answer {
        case .success:
            return nil
        case .other:
            return record
        case .refused(let status):
            guard var record else { return Record(count: 1, firstAt: now, lastAt: now, status: status) }
            record.count += 1
            record.lastAt = now
            record.status = status
            return record
        }
    }

    static func isLasting(_ record: Record?) -> Bool {
        guard let record else { return false }
        return record.count >= attempts && record.lastAt - record.firstAt >= span
    }

    /// Whether closing the sign-in sheet asks the feed again: only when a
    /// sign-in was saved or removed while it was open, which moves its
    /// moment. A sheet closed unchanged asks nothing and counts nothing, so
    /// the count measures refusals and not taps.
    static func asksAgainAfterSignIn(momentBefore: Double?, momentAfter: Double?) -> Bool {
        momentBefore != momentAfter
    }

    // MARK: - Store (device class, `AppStorageKeys.podcastFeedRefusals`)

    /// feed key ⇒ [count, firstAt, lastAt, status]
    static func all(defaults: UserDefaults = .standard) -> [String: Record] {
        var out: [String: Record] = [:]
        for (key, raw) in defaults.dictionary(forKey: AppStorageKeys.podcastFeedRefusals) ?? [:] {
            guard let values = raw as? [Double], values.count == 4 else { continue }
            out[key] = Record(count: Int(values[0]), firstAt: values[1], lastAt: values[2], status: Int(values[3]))
        }
        return out
    }

    /// Writes only when the record changed, so a quiet refresh leaves the
    /// defaults untouched.
    @discardableResult
    static func note(feedKey: String, _ answer: Answer, now: Double,
                     defaults: UserDefaults = .standard) -> Record? {
        var map = defaults.dictionary(forKey: AppStorageKeys.podcastFeedRefusals) ?? [:]
        let before = all(defaults: defaults)[feedKey]
        let after = next(before, answer, now: now)
        guard after != before else { return after }
        if let after {
            map[feedKey] = [Double(after.count), after.firstAt, after.lastAt, Double(after.status)]
        } else {
            map[feedKey] = nil
        }
        if map.isEmpty {
            defaults.removeObject(forKey: AppStorageKeys.podcastFeedRefusals)
        } else {
            defaults.set(map, forKey: AppStorageKeys.podcastFeedRefusals)
        }
        return after
    }

    static func forget(feedKey: String, defaults: UserDefaults = .standard) {
        note(feedKey: feedKey, .success, now: 0, defaults: defaults)
    }

    /// The feeds whose refusal is lasting.
    static func lasting(defaults: UserDefaults = .standard) -> Set<String> {
        Set(all(defaults: defaults).filter { isLasting($0.value) }.keys)
    }
}
