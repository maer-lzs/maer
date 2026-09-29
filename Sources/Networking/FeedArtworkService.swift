// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Resolves a podcast feed's CHANNEL artwork lazily and caches it.
/// Curated entries carry no artwork of their own (they never touch the
/// directory search that hands the catalog rows their images). But the
/// feeds all state one. Deliberately GENERIC, not a radio-play special
/// path: every future curation and every directory hit without artwork
/// inherits it.
///
/// Manners like the other lookup chains: identifying UA, a RANGED request
/// (the channel image sits in the first KB. No full feed parse, and the
/// body is cut off at the head size even when a server ignores Range),
/// session cache plus a persisted one INCLUDING negatives with a TTL.
actor FeedArtworkService {
    static let shared = FeedArtworkService()

    /// The store the results live in, as a suite name opened here (a
    /// `UserDefaults` cannot be sent into an actor). A witness hands in its
    /// own suite and reads it afterwards; the app passes nothing.
    private let defaults: UserDefaults

    init(suite: String? = nil) {
        self.defaults = suite.flatMap { UserDefaults(suiteName: $0) } ?? AppStorageKeys.store
    }

    private var cache: [String: URL?] = [:]   // feedURL → artwork (nil = negative)
    private var persistedLoaded = false

    /// The curation changes rarely. A generous span, but not eternal:
    /// public-broadcast image URLs rotate, which is exactly why nothing is
    /// hard-wired into the curation data. Written down in the door's one
    /// directory under `feed|<address>`; a negative for 7 days, a found
    /// picture for 30.
    private static let memoPrefix = "feed|"
    private static let positiveTTL: TimeInterval = 30 * 24 * 3600
    private static let negativeTTL: TimeInterval = 7 * 24 * 3600

    /// The two dictionaries of earlier builds: `feedArtworkResults` (v1,
    /// the poisoned generation, dropped) and `feedArtworkResults.v2`
    /// (`url`, `resolvedAt`; folded into the directory once with the spans
    /// it was written under). Returns how many entries moved.
    @discardableResult
    nonisolated static func adoptLegacy(defaults: UserDefaults = AppStorageKeys.store) -> Int {
        struct Old: Codable {
            var url: String?
            var resolvedAt: Double
        }
        defaults.removeObject(forKey: "feedArtworkResults")
        guard let data = defaults.data(forKey: "feedArtworkResults.v2") else { return 0 }
        defaults.removeObject(forKey: "feedArtworkResults.v2")
        // bearable, because an unreadable old list only costs notes; every question is then asked again
        guard let old = try? JSONDecoder().decode([String: Old].self, from: data) else { return 0 }
        var entries: [String: Artwork.Memo.Entry] = [:]
        for (feed, entry) in old {
            let span = entry.url == nil ? negativeTTL : positiveTTL
            entries[memoPrefix + feed] = .init(value: entry.url, resolvedAt: entry.resolvedAt,
                                               until: entry.resolvedAt + span, under: nil)
        }
        return Artwork.Memo.adopt(entries, defaults: defaults)
    }

    private func loadPersistedIfNeeded() {
        guard !persistedLoaded else { return }
        persistedLoaded = true
        Self.adoptLegacy(defaults: defaults)
        for (feed, answer) in Artwork.Memo.answers(prefix: Self.memoPrefix, defaults: defaults) {
            switch answer {
            case .found(let raw): cache[feed] = URL(string: raw)
            case .missing: cache[feed] = URL?.none
            }
        }
    }

    private func persistResult(feedURL: String, url: URL?) {
        let now = Date().timeIntervalSince1970
        Artwork.Memo.remember(Self.memoPrefix + feedURL, value: url?.absoluteString,
                              until: now + (url == nil ? Self.negativeTTL : Self.positiveTTL), now: now,
                              defaults: defaults)
    }

    /// The channel artwork for a feed; nil when the feed states none (cached
    /// as a negative, so a miss costs one request, not one per appearance).
    /// `fetch` is injectable: the failure-vs-absence decision is what the
    /// witness pins, not the transport.
    func artworkURL(feedURL: String,
                    fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse?) = { try await RequestRetryPolicy.fetch($0) }) async -> URL? {
        loadPersistedIfNeeded()
        if let cached = cache[feedURL] { return cached }
        // Source gate for NEW lookups only. Anything already resolved keeps
        // showing (the effect line promises exactly that).
        guard ExternalSources.isAllowed(ExternalSources.feedArtwork) else { return nil }
        guard let url = PodcastFeedAddress.requestURL(feedURL),
              await NetworkMonitor.shared.isConnected else { return nil }

        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-\(FeedArtworkLookup.headByteCount - 1)", forHTTPHeaderField: "Range")
        var resolved: URL?
        let started = Date()
        do {
            let (data, http) = try await fetch(request)
            let ok = (http?.statusCode).map { (200...299).contains($0) } ?? true
            Logger.rss.notice("\(Self.fetchLine(feed: PodcastSubscriptions.maskedFeedURL(feedURL), status: http?.statusCode, bytes: data.count, ms: Int(Date().timeIntervalSince(started) * 1000), reason: ok ? "ok" : "status=\(http?.statusCode ?? 0)"), privacy: .public)")
            if let status = http?.statusCode, !(200...299).contains(status) {
                // Failure ≠ absence. Only "there is none" is an answer about
                // the picture: a feed that is gone has no channel image, and
                // that is booked like a head that names none. A refusal, a
                // pause or a server error is a failure: session-only,
                // retried next time. A 401 page read as "feed states no
                // image" once persisted a 7-day negative.
                let meaning = StatusMeaning.from(status: status)
                guard meaning.isAbsence else {
                    Logger.rss.error("HOERSPIEL artwork feed=\(PodcastSubscriptions.maskedFeedURL(feedURL), privacy: .public) → FAILED: HTTP \(status) \(String(describing: meaning), privacy: .public)")
                    return nil
                }
                resolved = nil
            } else {
                // A server ignoring Range would hand out the whole feed. Cut
                // it down before parsing so the promise "head only" holds
                // either way.
                let head = String(decoding: data.prefix(FeedArtworkLookup.headByteCount), as: UTF8.self)
                resolved = FeedArtworkLookup.channelImageURL(fromHead: head)
            }
        } catch {
            Logger.rss.notice("\(Self.fetchLine(feed: PodcastSubscriptions.maskedFeedURL(feedURL), status: nil, bytes: 0, ms: Int(Date().timeIntervalSince(started) * 1000), reason: ArchiveOrgClient.fetchReason(error)), privacy: .public)")
            // A failed fetch is NOT a negative result. No caching, the next
            // appearance may well succeed (offline, transient 5xx).
            Logger.rss.error("HOERSPIEL artwork feed=\(PodcastSubscriptions.maskedFeedURL(feedURL), privacy: .public) → FAILED: \(String(describing: error), privacy: .public)")
            return nil
        }
        cache[feedURL] = resolved
        persistResult(feedURL: feedURL, url: resolved)
        Logger.rss.notice("HOERSPIEL artwork feed=\(PodcastSubscriptions.maskedFeedURL(feedURL), privacy: .public) → \(resolved == nil ? "miss" : "hit", privacy: .public)")
        return resolved
    }

    /// One line per network fetch of a feed head, in the shape of the
    /// catalogue's metadata line, so a device log counts both the same way:
    /// runs, and why each one ended. The feed address is masked.
    nonisolated static func fetchLine(feed: String, status: Int?, bytes: Int, ms: Int, reason: String) -> String {
        "FEEDART fetch feed=\(feed) status=\(status.map(String.init) ?? "-") bytes=\(bytes) ms=\(ms) reason=\(reason)"
    }
}
