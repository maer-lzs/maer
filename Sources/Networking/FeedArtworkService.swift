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

    private var cache: [String: URL?] = [:]   // feedURL → artwork (nil = negative)
    private var persistedLoaded = false

    /// The curation changes rarely. A generous TTL, but not eternal:
    /// public-broadcast image URLs rotate, which is exactly why nothing is
    /// hard-wired into the curation data.
    /// `v2` discards the poisoned generation. Entries written
    /// while a 401 body was mistaken for "feed states no image" (server
    /// connected before its artwork endpoint was open) healed only after the
    /// 7-day TTL otherwise. Same storageVersion move as the radio logos.
    private static let persistKey = "feedArtworkResults.v2"
    private static let legacyPersistKey = "feedArtworkResults"
    private static let positiveTTL: TimeInterval = 30 * 24 * 3600
    private static let negativeTTL: TimeInterval = 7 * 24 * 3600

    private struct Stored: Codable {
        var url: String?
        var resolvedAt: Double
    }

    private func loadPersistedIfNeeded() {
        guard !persistedLoaded else { return }
        persistedLoaded = true
        AppStorageKeys.remove(Self.legacyPersistKey)
        guard let data = AppStorageKeys.data(Self.persistKey),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else { return }
        let now = Date().timeIntervalSince1970
        for (feed, entry) in stored {
            let ttl = entry.url == nil ? Self.negativeTTL : Self.positiveTTL
            if now - entry.resolvedAt > ttl { continue }
            cache[feed] = entry.url.flatMap(URL.init(string:))
        }
    }

    private func persistResult(feedURL: String, url: URL?) {
        var stored = AppStorageKeys.data(Self.persistKey)
            .flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        stored[feedURL] = Stored(url: url?.absoluteString, resolvedAt: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(stored) {
            AppStorageKeys.set(data, for: Self.persistKey)
        }
    }

    /// The channel artwork for a feed; nil when the feed states none (cached
    /// as a negative, so a miss costs one request, not one per appearance).
    /// `fetch` is injectable (U4 fence): the failure-vs-absence decision is
    /// what the test pins, not the transport.
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
        do {
            let (data, http) = try await fetch(request)
            // Failure ≠ absence. The radio-logo distinction
            // (failure/empty/data). fetch returns non-2xx WITH its error body,
            // and a 401 page read as "feed states no image" persisted a
            // 7-day negative (a server can be connected before its artwork endpoint
            // opened). Only a SUCCESSFULLY read head may answer "no image";
            // any other status is a failure: session-only, retried next time.
            if let status = http?.statusCode, !(200...299).contains(status) {
                Logger.rss.error("HOERSPIEL artwork feed=\(feedURL, privacy: .public) → FAILED: HTTP \(status)")
                return nil
            }
            // A server ignoring Range would hand out the whole feed. Cut it
            // down before parsing so the promise "head only" holds either way.
            let head = String(decoding: data.prefix(FeedArtworkLookup.headByteCount), as: UTF8.self)
            resolved = FeedArtworkLookup.channelImageURL(fromHead: head)
        } catch {
            // A failed fetch is NOT a negative result. No caching, the next
            // appearance may well succeed (offline, transient 5xx).
            Logger.rss.error("HOERSPIEL artwork feed=\(feedURL, privacy: .public) → FAILED: \(String(describing: error), privacy: .public)")
            return nil
        }
        cache[feedURL] = resolved
        persistResult(feedURL: feedURL, url: resolved)
        Logger.rss.notice("HOERSPIEL artwork feed=\(feedURL, privacy: .public) → \(resolved == nil ? "miss" : "hit", privacy: .public)")
        return resolved
    }
}
