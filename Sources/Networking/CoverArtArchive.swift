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
/// detail view opens. Never as a sweep over the library.
actor CoverArtArchive {
    static let shared = CoverArtArchive()

    private var lastRequestAt: Date = .distantPast
    /// MBIDs known to have no front cover (negative cache for this session).
    private var missing: Set<String> = []

    nonisolated static func frontURL(mbid: String) -> URL? {
        URL(string: "https://coverartarchive.org/release/\(mbid)/front-1200")
    }

    /// High-res front cover for a release MBID. Nil when unavailable.
    /// The image lands in the shared ImageCache under its CAA URL, so the
    /// normal `CachedAsyncImage` path can render it afterwards.
    func frontCover(mbid: String) async -> UIImage? {
        // The SOURCE switch (MusicBrainz/CAA) sits above the feature
        // toggle: source off means zero requests to its hosts, however the
        // finer hi-res preference is set.
        guard AppStorageKeys.musicHighResCoversValue,
              ExternalSources.isAllowed(ExternalSources.musicBrainz) else { return nil }
        guard !missing.contains(mbid), let url = Self.frontURL(mbid: mbid) else { return nil }
        if let cached = await Artwork.full(for: url) { return cached }
        guard await NetworkMonitor.shared.isConnected else { return nil }

        // Serialize: at most one request per second (MusicBrainz policy).
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < 1.0 {
            try? await Task.sleep(nanoseconds: UInt64((1.0 - elapsed) * 1_000_000_000))
        }
        lastRequestAt = Date()

        // The one door: the cover lane with the app's identifying user
        // agent, the picture cached behind it.
        guard let image = await Artwork.image(for: url)?.image else {
            missing.insert(mbid)
            return nil
        }
        return image
    }

    /// MusicBrainz policy requires an identifying User-Agent.
    /// ONE identifier for the whole app. See AppUserAgent.
    nonisolated static let userAgent = AppUserAgent.value
}
