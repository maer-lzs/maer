// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How the app asks a foreign service: how many requests at once, how far
/// apart, and how long a whole host rests after it said "not now".
///
/// Measured before the rule (a scroll run of 24.09.): 23 answers 429 from
/// archive.org in one minute, while every tile asked at once and a 429 was
/// asked again after 0.4 s and 1.2 s. Three actors each kept their own one
/// second for MusicBrainz, so together they could ask it three times in the
/// same second.
nonisolated enum HostCourtesyRule {
    /// What a host is allowed.
    struct Allowance: Equatable, Sendable {
        /// Requests in flight at once; nil is no cap (the person's own
        /// servers).
        let concurrent: Int?
        /// The least time between two starts, shared by the whole group.
        let spacing: Duration?
    }

    /// Requests at once for a foreign host without a rule of its own.
    static let concurrent = 4

    /// Hosts with a published rule of their own, by group: MusicBrainz asks
    /// for at most one request per second, and the Cover Art Archive is
    /// run by the same foundation under the same rule.
    static let groups: [String: [String]] = [
        "musicbrainz": ["musicbrainz.org", "coverartarchive.org"],
    ]

    /// The group a host belongs to: a listed domain or one of its
    /// subdomains, else the host itself.
    static func group(of host: String) -> String {
        let host = host.lowercased()
        for (name, domains) in groups where domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return name
        }
        return host
    }

    static func allowance(group: String, isOwnServer: Bool) -> Allowance {
        if groups[group] != nil { return Allowance(concurrent: 1, spacing: .seconds(1)) }
        if isOwnServer { return Allowance(concurrent: nil, spacing: nil) }
        return Allowance(concurrent: concurrent, spacing: nil)
    }

    /// Whether an answer tells the whole host to rest.
    static func asksToRest(status: Int) -> Bool {
        status == 429 || status == 503
    }

    /// The longest rest honoured: a host that names more is resting for
    /// this session in effect, and one hour keeps a wrong header from
    /// silencing a source until the app is killed.
    static let longestRest: Duration = .seconds(3600)

    /// The rest a host asked for. `Retry-After` in seconds or as an HTTP
    /// date; without one, 2, 4, 8 … seconds for each rest in a row, up to
    /// a minute.
    static func rest(retryAfter: String?, restsInARow: Int, now: Date) -> Duration {
        if let named = retryAfter.flatMap({ seconds(fromRetryAfter: $0, now: now) }) {
            return min(.seconds(max(named, 0)), longestRest)
        }
        let doubling = min(max(restsInARow, 0), 5)
        return .seconds(min(2 << doubling, 60))
    }

    /// `Retry-After: 120` or `Retry-After: Wed, 21 Oct 2026 07:28:00 GMT`.
    static func seconds(fromRetryAfter raw: String, now: Date) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let plain = Int(trimmed) { return plain }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return Int(date.timeIntervalSince(now).rounded(.up))
    }

    /// A rest this long is waited out by the request that meets it; a
    /// longer one ends the request without asking.
    static let longestWait: Duration = .seconds(30)
}
