// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import UIKit

/// High-resolution covers from the Cover Art Archive (open, no key),
/// keyed by the release MBID that OpenSubsonic servers expose. Policy-clean:
/// a proper User-Agent, requests strictly serialized at ~1 req/s (MB rate
/// limit), aggressively cached via ImageCache, fetched only ON DEMAND when a
/// detail view opens — never as a sweep over the library.
actor CoverArtArchive {
    static let shared = CoverArtArchive()

    private var lastRequestAt: Date = .distantPast
    /// MBIDs known to have no front cover (negative cache for this session).
    private var missing: Set<String> = []

    nonisolated static func frontURL(mbid: String) -> URL? {
        URL(string: "https://coverartarchive.org/release/\(mbid)/front-1200")
    }

    /// High-res front cover for a release MBID — nil when unavailable.
    /// The image lands in the shared ImageCache under its CAA URL, so the
    /// normal `CachedAsyncImage` path can render it afterwards.
    func frontCover(mbid: String) async -> UIImage? {
        guard AppStorageKeys.musicHighResCoversValue else { return nil }
        guard !missing.contains(mbid), let url = Self.frontURL(mbid: mbid) else { return nil }
        if let cached = await ImageCache.shared.image(for: url) { return cached }
        guard await NetworkMonitor.shared.isConnected else { return nil }

        // Serialize: at most one request per second (MusicBrainz policy).
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < 1.0 {
            try? await Task.sleep(nanoseconds: UInt64((1.0 - elapsed) * 1_000_000_000))
        }
        lastRequestAt = Date()

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, http) = try? await RequestRetryPolicy.fetch(request),
              http?.statusCode == 200,
              let image = UIImage(data: data) else {
            missing.insert(mbid)
            return nil
        }
        await ImageCache.shared.set(image, data: data, for: url)
        return image
    }

    /// MusicBrainz policy requires an identifying User-Agent.
    /// EINE Kennung fuer die ganze App — siehe AppUserAgent.
    nonisolated static let userAgent = AppUserAgent.value
}
