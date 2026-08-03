// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit
import OSLog

/// e4bd910: the radio-logo fallback chain BEHIND the gated favicon —
/// Wikidata P154 first, then the homepage apple-touch-icon, then nothing
/// (placeholder). Reuses the portrait chain's manners: identifying UA,
/// ~1 req/s politeness, session cache INCLUDING negatives (a no-hit never
/// re-asks), opt-out on the network-services page (`radioLogoChainEnabled`).
/// Images ride the shared ImageCache (persistent).
actor RadioLogoService {
    static let shared = RadioLogoService()

    private var cache: [String: URL?] = [:]   // stationID → resolved logo URL (nil = negative)
    private var lastRequest = Date.distantPast

    private func politeDelay() async {
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < 1.0 {
            try? await Task.sleep(nanoseconds: UInt64((1.0 - elapsed) * 1_000_000_000))
        }
        lastRequest = Date()
    }

    private func fetch(_ url: URL) async -> Data? {
        await politeDelay()
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        return try? await URLSession.shared.data(for: request).0
    }

    /// The resolved logo URL for a station, chain order fixed; every outcome
    /// (incl. nil) is session-cached.
    func logoURL(stationID: String, name: String, homepage: String?) async -> URL? {
        if let cached = cache[stationID] { return cached }
        guard AppStorageKeys.radioLogoChainEnabledValue else { return nil }
        let resolved = await resolve(name: name, homepage: homepage)
        cache[stationID] = resolved
        if resolved == nil {
            Logger.library.notice("RADIO logo chain: no hit for \(name, privacy: .public)")
        }
        return resolved
    }

    private func resolve(name: String, homepage: String?) async -> URL? {
        // Stage 1: Wikidata P154 (the agreed FIRST fallback).
        if let searchURL = RadioLogoLookup.wikidataSearchURL(name: name),
           let searchData = await fetch(searchURL),
           let entity = RadioLogoLookup.matchedEntityId(fromSearchData: searchData, stationName: name),
           let entityURL = ArtistPortraitLookup.wikidataEntityURL(entity),
           let entityData = await fetch(entityURL),
           let fileName = RadioLogoLookup.p154FileName(fromEntityData: entityData, entity: entity),
           let thumb = ArtistPortraitLookup.commonsThumbURL(fileName: fileName) {
            return thumb
        }
        // Stage 2: homepage apple-touch-icon (first-party).
        guard let homepage, let pageURL = URL(string: homepage),
              pageURL.scheme?.hasPrefix("http") == true else { return nil }
        if let html = await fetch(pageURL).flatMap({ String(data: $0, encoding: .utf8) }),
           let icon = RadioLogoLookup.extractTouchIcon(html: html, baseURL: pageURL) {
            return icon
        }
        return RadioLogoLookup.conventionTouchIconURL(homepage: pageURL)
    }
}
