// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import UIKit
import OSLog

/// Best-effort now-playing cover art for live radio. From the ICY
/// "Artist - Title" it searches MusicBrainz for the recording, takes the first
/// release MBID and pulls the front cover from the Cover Art Archive (both open,
/// no key). Net-gated and MusicBrainz-polite: the identity and the one second
/// between requests come from the ways out and the courtesy rule, shared with
/// every other MusicBrainz asker. Everything is cached for the session. Including
/// negatives. So a stream that repeats a song never re-queries. nil means
/// "keep the station logo" (coverage is patchy; no cover is normal).
actor RadioArtworkService {
    static let shared = RadioArtworkService()

    private var covers: [String: URL] = [:]     // cacheKey → resolved CAA front URL
    private var missing: Set<String> = []       // cacheKey with no usable cover

    func artwork(artist: String, title: String) async -> UIImage? {
        guard RadioArtworkLookup.shouldLookup(artist: artist, title: title) else { return nil }
        let key = RadioArtworkLookup.cacheKey(artist: artist, title: title)
        if missing.contains(key) { return nil }
        if let coverURL = covers[key] { return await image(from: coverURL, key: key) }

        // The ICY cover chain never had a switch (booked as a gap when the
        // uniform opt-out semantics landed). The MusicBrainz SOURCE switch is
        // that switch now; cached covers above keep showing.
        guard ExternalSources.isAllowed(ExternalSources.musicBrainz) else { return nil }
        guard await NetworkMonitor.shared.isConnected,
              let queryURL = RadioArtworkLookup.musicBrainzQueryURL(artist: artist, title: title) else {
            return nil
        }
        var request = URLRequest(url: queryURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            let (body, http) = try await RequestRetryPolicy.fetch(request)
            if let status = http?.statusCode, !(200...299).contains(status) {
                // Only "there is none" is an answer about this recording. A
                // refusal or a pause books nothing, so the next song asks
                // again instead of wearing the station logo all session.
                if StatusMeaning.from(status: status).isAbsence { missing.insert(key) }
                return nil
            }
            data = body
        } catch {
            // Transport says nothing about the cover: nothing is booked.
            Logger.library.notice("RADIO cover lookup failed reason=\(String(describing: error), privacy: .public)")
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(MBRecordingResponse.self, from: data),
              let mbid = RadioArtworkLookup.firstReleaseMBID(decoded),
              let coverURL = CoverArtArchive.frontURL(mbid: mbid) else {
            missing.insert(key)
            return nil
        }
        covers[key] = coverURL
        return await image(from: coverURL, key: key)
    }

    private func image(from url: URL, key: String) async -> UIImage? {
        if let cached = await Artwork.full(for: url) { return cached }
        guard await NetworkMonitor.shared.isConnected else { return nil }
        // The one door fetches over the cover lane (with the app's
        // identifying user agent) and caches the picture.
        guard let image = await Artwork.image(for: url)?.image else {
            missing.insert(key)
            return nil
        }
        return image
    }
}
