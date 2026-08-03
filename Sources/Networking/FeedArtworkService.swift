// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// c125ccd: resolves a podcast feed's CHANNEL artwork lazily and caches it.
/// Curated entries carry no artwork of their own (they never touch the
/// directory search that hands the catalog rows their images) — but the
/// feeds all state one. Deliberately GENERIC, not a radio-play special
/// path: every future curation and every directory hit without artwork
/// inherits it (Regel 2).
///
/// Manners like the other lookup chains: identifying UA, a RANGED request
/// (the channel image sits in the first KB — no full feed parse, and the
/// body is cut off at the head size even when a server ignores Range),
/// session cache plus a persisted one INCLUDING negatives with a TTL.
actor FeedArtworkService {
    static let shared = FeedArtworkService()

    private var cache: [String: URL?] = [:]   // feedURL → artwork (nil = negative)
    private var persistedLoaded = false

    /// The curation changes rarely — a generous TTL, but not eternal:
    /// public-broadcast image URLs rotate, which is exactly why nothing is
    /// hard-wired into the curation data.
    private static let persistKey = "feedArtworkResults"
    private static let positiveTTL: TimeInterval = 30 * 24 * 3600
    private static let negativeTTL: TimeInterval = 7 * 24 * 3600

    private struct Stored: Codable {
        var url: String?
        var resolvedAt: Double
    }

    private func loadPersistedIfNeeded() {
        guard !persistedLoaded else { return }
        persistedLoaded = true
        guard let data = UserDefaults.standard.data(forKey: Self.persistKey),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else { return }
        let now = Date().timeIntervalSince1970
        for (feed, entry) in stored {
            let ttl = entry.url == nil ? Self.negativeTTL : Self.positiveTTL
            if now - entry.resolvedAt > ttl { continue }
            cache[feed] = entry.url.flatMap(URL.init(string:))
        }
    }

    private func persistResult(feedURL: String, url: URL?) {
        var stored = UserDefaults.standard.data(forKey: Self.persistKey)
            .flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        stored[feedURL] = Stored(url: url?.absoluteString, resolvedAt: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

    /// The channel artwork for a feed; nil when the feed states none (cached
    /// as a negative, so a miss costs one request, not one per appearance).
    func artworkURL(feedURL: String) async -> URL? {
        loadPersistedIfNeeded()
        if let cached = cache[feedURL] { return cached }
        guard let url = URL(string: feedURL), await NetworkMonitor.shared.isConnected else { return nil }

        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-\(FeedArtworkLookup.headByteCount - 1)", forHTTPHeaderField: "Range")
        var resolved: URL?
        do {
            let (data, _) = try await RequestRetryPolicy.fetch(request)
            // A server ignoring Range would hand out the whole feed — cut it
            // down before parsing so the promise "head only" holds either way.
            let head = String(decoding: data.prefix(FeedArtworkLookup.headByteCount), as: UTF8.self)
            resolved = FeedArtworkLookup.channelImageURL(fromHead: head)
        } catch {
            // A failed fetch is NOT a negative result — no caching, the next
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
