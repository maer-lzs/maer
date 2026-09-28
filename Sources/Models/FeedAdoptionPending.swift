// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Feeds that arrived over the account (subscription family) but could
/// not be followed on this device: the feed demanded a sign-in, is gone,
/// timed out, was unreachable or unreadable. Visible instead of failing
/// silently on every reconcile. The marker stops the endless retry: an
/// adoption skips a marked feed until the person retries, signs in or
/// removes it. Pure rules over a UserDefaults dictionary
/// (feed key ⇒ address, reason, status).
nonisolated enum FeedAdoptionPending {
    enum Reason: String, Sendable, CaseIterable, Equatable {
        /// 401 or 403: credentials, not "gone" or "down".
        case signIn
        /// 401 or 403 at an address that carries its access in itself (a
        /// token in the link) and has no credentials here: there is nothing
        /// to sign in with; the subscription may have ended or the link is
        /// no longer valid.
        case accessRefused
        /// 404 or 410: the address names nothing any more.
        case notFound
        /// Another non-2xx answer; `status` carries it.
        case server
        case timeout
        case unreachable
        /// A 2xx whose body is no feed.
        case unreadable
        /// The person dismissed the placeholder HERE. A local choice: the
        /// account keeps the subscription, this device stops offering it
        /// until a newer statement arrives.
        case dismissed

        /// The feed's reading of the shared meaning. A pause that survived
        /// the ladder is a server answer here; `status` carries the 429.
        init(_ meaning: StatusMeaning) {
            switch meaning {
            case .signIn: self = .signIn
            case .notFound: self = .notFound
            case .throttled, .server: self = .server
            }
        }

        static func from(status: Int) -> Reason {
            Reason(StatusMeaning.from(status: status))
        }

        /// The reading for one feed: a refusal at a token address without
        /// credentials is `accessRefused`, never "needs a sign-in".
        static func from(meaning: StatusMeaning, tokenAddress: Bool, hasCredentials: Bool) -> Reason {
            let reason = Reason(meaning)
            return reason == .signIn && tokenAddress && !hasCredentials ? .accessRefused : reason
        }
    }

    struct Entry: Equatable, Sendable {
        var feedURL: String
        var reason: Reason
        var status: Int?
        /// The stamp of the account statement this marker answers. A newer
        /// statement (the person subscribed again elsewhere) beats it.
        var statementT: Double? = nil
    }

    /// What became of one subscription the account offered, in the words of
    /// the log line: followed, skipped as the free twin of a held premium
    /// feed (the store answers yes without holding it), or marked with the
    /// reason. One reading per offer, so a feed that does not arrive says
    /// why on the device, not only in the code.
    static func outcome(ok: Bool, held: Bool, reason: Reason?) -> String {
        guard ok else { return "marked reason=\(reason?.rawValue ?? "none")" }
        return held ? "followed" : "twin"
    }

    /// The reason a feed could not be followed, as a short phrase. The ONE
    /// wording for the "Not followed yet" section and the import summary.
    static func phrase(_ reason: Reason, status: Int?) -> String {
        switch reason {
        case .signIn: return String(localized: "needs a sign-in")
        case .accessRefused: return String(localized: "access refused: the subscription may have ended or the link is no longer valid")
        case .notFound: return String(localized: "feed not found")
        case .timeout: return String(localized: "timed out")
        case .unreachable: return String(localized: "not reachable")
        case .unreadable: return String(localized: "feed unreadable")
        case .server: return String(localized: "server answered \(status ?? 0)")
        // Dismissed placeholders are filtered out before any surface shows
        // them; the case exists for exhaustiveness only.
        case .dismissed: return "dismissed"
        }
    }

    /// The two answers that mean "credentials", not "gone" or "down".
    static func demandsSignIn(status: Int?) -> Bool {
        status.map { Reason.from(status: $0) == .signIn } ?? false
    }

    static func pending(defaults: UserDefaults = .standard) -> [String: Entry] {
        var out: [String: Entry] = [:]
        for (key, raw) in defaults.dictionary(forKey: AppStorageKeys.podcastFeedsNeedingSignIn) ?? [:] {
            if let map = raw as? [String: String], let url = map["url"],
               let reason = map["reason"].flatMap(Reason.init(rawValue:)) {
                out[key] = Entry(feedURL: url, reason: reason, status: map["status"].flatMap(Int.init),
                                 statementT: map["t"].flatMap(Double.init))
            } else if let url = raw as? String {
                // The first shape stored the address only, for the sign-in
                // case alone.
                out[key] = Entry(feedURL: url, reason: .signIn, status: nil)
            }
        }
        return out
    }

    /// Posted when access to feeds may have arrived: a Mär sync sign-in, or
    /// another device's feed credentials applied here. `userInfo["by"]`
    /// names the occasion.
    static let accessArrived = Notification.Name("FeedAdoptionAccessArrived")

    /// The feeds that get exactly one fresh attempt when access arrived:
    /// those refused for access (a sign-in, or a token link that may have
    /// travelled anew). A dismissed or a missing feed is not the access's to
    /// fix.
    static func retryOnNewAccess(_ pending: [String: Entry]) -> [String] {
        pending.filter { $0.value.reason == .signIn || $0.value.reason == .accessRefused }.map(\.key).sorted()
    }

    /// May the adoption fetch this feed? No while it is marked, unless the
    /// account brought a NEWER statement than the marker answered: then the
    /// person acted again elsewhere and the marker is spent.
    static func shouldAttempt(feedKey: String, statementT: Double? = nil,
                              defaults: UserDefaults = .standard) -> Bool {
        guard let entry = pending(defaults: defaults)[feedKey] else { return true }
        if let statementT, let answered = entry.statementT, statementT > answered { return true }
        return false
    }

    static func mark(feedKey: String, feedURL: String, reason: Reason, status: Int? = nil,
                     statementT: Double? = nil, defaults: UserDefaults = .standard) {
        var map = defaults.dictionary(forKey: AppStorageKeys.podcastFeedsNeedingSignIn) ?? [:]
        var entry = ["url": feedURL, "reason": reason.rawValue]
        if let status { entry["status"] = String(status) }
        if let statementT { entry["t"] = String(statementT) }
        map[feedKey] = entry
        defaults.set(map, forKey: AppStorageKeys.podcastFeedsNeedingSignIn)
    }

    /// Idempotent: clearing an unmarked key changes nothing.
    static func clear(feedKey: String, defaults: UserDefaults = .standard) {
        var map = defaults.dictionary(forKey: AppStorageKeys.podcastFeedsNeedingSignIn) ?? [:]
        guard map.removeValue(forKey: feedKey) != nil else { return }
        if map.isEmpty {
            defaults.removeObject(forKey: AppStorageKeys.podcastFeedsNeedingSignIn)
        } else {
            defaults.set(map, forKey: AppStorageKeys.podcastFeedsNeedingSignIn)
        }
    }
}
