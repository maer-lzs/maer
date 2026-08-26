// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Fetches missing artist portraits the vision-conform way: SERVER image
/// first (always wins, resolved by the caller/provider), then MusicBrainz →
/// Wikidata (P18) → Wikimedia Commons. No key, open sources, exactly the
/// overlay principle of Lyrics/LRCLIB and the CAA covers. MusicBrainz-polite
/// like `RadioArtworkService`: identifying User-Agent, at most ONE request
/// per second, lazy (visible cells only. Never a bulk prefetch), session
/// cache including negatives; the images themselves ride the persistent
/// `ImageCache` via `CachedAsyncImage`. Net-gated and opt-out
/// (`musicArtistImagesOnline`). Offline or off just means color circles.
actor ArtistPortraitService {
    static let shared = ArtistPortraitService()
    private init() {}

    /// artistId → resolved portrait URL (nil = known-absent; also cached).
    private var cache: [String: URL?] = [:]
    private var lastRequest = Date.distantPast

    /// Used to carry the PRIVATE forge address outside. Now the one shared
    /// identifier (AppUserAgent).
    private static let userAgent = AppUserAgent.value

    /// Resolve the portrait for an artist: server URL wins immediately;
    /// otherwise the MB→Wikidata→Commons chain (MBID direct, else a
    /// conservative unique-hit name search. A color circle beats a wrong
    /// face). Every outcome is cached for the session.
    func portraitURL(artistId: String, name: String?, serverImageURL: URL?,
                     musicBrainzId: String?) async -> URL? {
        if let serverImageURL {
            cache[artistId] = serverImageURL
            return serverImageURL
        }
        // Opt-out means NEITHER load NOR show. With the toggle off
        // only the server image above may pass; cached WEB portraits stay on
        // disk (toggle back on ⇒ instantly back, no re-fetch) but never render.
        guard AppStorageKeys.musicArtistImagesOnlineValue else { return nil }
        if let cached = cache[artistId] { return cached }
        guard await NetworkMonitor.shared.isConnected else { return nil }

        let resolved = await resolveViaChain(name: name, musicBrainzId: musicBrainzId)
        cache[artistId] = resolved   // negatives too — no re-search per render
        return resolved
    }

    private func resolveViaChain(name: String?, musicBrainzId: String?) async -> URL? {
        // 1) The MB artist (by MBID, else conservative name search).
        var mbid = musicBrainzId
        if mbid == nil || mbid?.isEmpty == true {
            guard let name, !name.isEmpty,
                  let searchURL = ArtistPortraitLookup.artistSearchURL(name: name),
                  let data = await politeFetch(searchURL),
                  let response = try? JSONDecoder().decode(MBArtistSearchResponse.self, from: data)
            else { return nil }
            mbid = ArtistPortraitLookup.uniqueSearchHit(response, name: name)
        }
        guard let mbid, let artistURL = ArtistPortraitLookup.artistByMBIDURL(mbid),
              let artistData = await politeFetch(artistURL),
              let artist = try? JSONDecoder().decode(MBArtistResponse.self, from: artistData),
              let entity = ArtistPortraitLookup.wikidataEntity(artist) else { return nil }
        // 2) Wikidata P18 → Commons thumbnail.
        guard let entityURL = ArtistPortraitLookup.wikidataEntityURL(entity),
              let entityData = await politeFetch(entityURL),
              let file = ArtistPortraitLookup.p18FileName(fromEntityData: entityData, entity: entity)
        else { return nil }
        return ArtistPortraitLookup.commonsThumbURL(fileName: file)
    }

    /// Same politeness contract as RadioArtworkService: ≤1 request/second,
    /// identifying UA, best-effort (nil on any failure. Never an error).
    private func politeFetch(_ url: URL) async -> Data? {
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < 1.0 {
            try? await Task.sleep(nanoseconds: UInt64((1.0 - elapsed) * 1_000_000_000))
        }
        lastRequest = Date()
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, http) = try? await RequestRetryPolicy.fetch(request),
              http?.statusCode == 200 else { return nil }
        return data
    }
}
