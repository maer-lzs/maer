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

    /// artist key → resolved portrait URL (nil = known-absent; also cached).
    /// The key is the artist's id WITH its source: two music servers can
    /// hand out the same raw number for two different artists.
    private var cache: [String: URL?] = [:]

    /// Resolve the portrait for an artist: server URL wins immediately;
    /// otherwise the MB→Wikidata→Commons chain (MBID direct, else a
    /// conservative unique-hit name search. A color circle beats a wrong
    /// face). Every outcome is cached for the session.
    func portraitURL(artistKey: String, name: String?, serverImageURL: URL?,
                     musicBrainzId: String?) async -> URL? {
        if let serverImageURL {
            cache[artistKey] = serverImageURL
            return serverImageURL
        }
        // Opt-out means NEITHER load NOR show. With the toggle off
        // only the server image above may pass; cached WEB portraits stay on
        // disk (toggle back on ⇒ instantly back, no re-fetch) but never render.
        guard AppStorageKeys.musicArtistImagesOnlineValue else { return nil }
        if let cached = cache[artistKey] { return cached }
        guard await NetworkMonitor.shared.isConnected else { return nil }
        // A tile stays a moment before the chain is asked (`TileDwell`);
        // a tile that left asks nothing.
        guard await TileDwell.stood(TileDwell.lookup) else { return nil }

        let started = Date()
        let answer = await resolveViaChain(name: name, musicBrainzId: musicBrainzId)
        IndexRunLine.write(kind: "portrait", id: artistKey, started: started, reason: answer.reason)
        switch answer {
        case .portrait(let url):
            cache[artistKey] = url
            return url
        case .none:
            // A clean "no portrait" is kept for the session: no re-search
            // per render.
            cache[artistKey] = URL?.none
            return nil
        case .failed:
            // A refusal, a pause or a transport failure says nothing about
            // the artist: nothing is kept, the next render may ask again.
            return nil
        }
    }

    /// What the chain came back with, kept apart on purpose: only a clean
    /// "none" may be remembered.
    private enum ChainAnswer {
        case portrait(URL)
        case none
        case failed

        /// The word of the counting line.
        var reason: String {
            switch self {
            case .portrait: "ok"
            case .none: "none"
            case .failed: "failed"
            }
        }
    }

    /// What one hop came back with: the body, a clean "not there", or an
    /// answer that says nothing (refusal, pause, server error, transport).
    private enum Fetched {
        case data(Data)
        case absent
        case failed
    }

    private func resolveViaChain(name: String?, musicBrainzId: String?) async -> ChainAnswer {
        // 1) The MB artist (by MBID, else conservative name search).
        var mbid = musicBrainzId
        if mbid == nil || mbid?.isEmpty == true {
            guard let name, !name.isEmpty,
                  let searchURL = ArtistPortraitLookup.artistSearchURL(name: name) else { return .none }
            switch await politeFetch(searchURL) {
            case .failed: return .failed
            case .absent: return .none
            case .data(let data):
                guard let response = try? JSONDecoder().decode(MBArtistSearchResponse.self, from: data)
                else { return .none }
                mbid = ArtistPortraitLookup.uniqueSearchHit(response, name: name)
            }
        }
        guard let mbid, let artistURL = ArtistPortraitLookup.artistByMBIDURL(mbid) else { return .none }
        let entity: String
        switch await politeFetch(artistURL) {
        case .failed: return .failed
        case .absent: return .none
        case .data(let artistData):
            guard let artist = try? JSONDecoder().decode(MBArtistResponse.self, from: artistData),
                  let found = ArtistPortraitLookup.wikidataEntity(artist) else { return .none }
            entity = found
        }
        // 2) Wikidata P18 → Commons thumbnail.
        guard let entityURL = ArtistPortraitLookup.wikidataEntityURL(entity) else { return .none }
        switch await politeFetch(entityURL) {
        case .failed: return .failed
        case .absent: return .none
        case .data(let entityData):
            guard let file = ArtistPortraitLookup.p18FileName(fromEntityData: entityData, entity: entity),
                  let url = ArtistPortraitLookup.commonsThumbURL(fileName: file) else { return .none }
            return .portrait(url)
        }
    }

    /// The pace is the courtesy rule's (MusicBrainz one per second, shared
    /// with every other asker; Wikidata and Commons like any foreign host),
    /// no error is thrown, but a failure is told apart from an absence,
    /// because only the absence may be remembered.
    private func politeFetch(_ url: URL) async -> Fetched {
        let request = URLRequest(url: url)
        do {
            let (data, http) = try await RequestRetryPolicy.fetch(request)
            if let status = http?.statusCode, !(200...299).contains(status) {
                return StatusMeaning.from(status: status).isAbsence ? .absent : .failed
            }
            return .data(data)
        } catch {
            Logger.music.notice("ARTIST portrait hop failed reason=\(String(describing: error), privacy: .public)")
            return .failed
        }
    }
}
