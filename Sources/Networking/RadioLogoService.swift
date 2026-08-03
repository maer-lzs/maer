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

    /// 275f379 (2): resolved chain results PERSIST — the 1-req/s politeness
    /// queue is paid ONCE per station, not once per session. Negatives carry
    /// a TTL (14 days) so a station that gains a logo is retried eventually.
    private static let persistKey = "radioLogoChainResults"
    private static let negativeTTL: TimeInterval = 14 * 24 * 3600
    private var persistedLoaded = false

    private struct Stored: Codable {
        var url: String?          // nil = negative hit
        var resolvedAt: Double    // epoch seconds
    }

    private func loadPersistedIfNeeded() {
        guard !persistedLoaded else { return }
        persistedLoaded = true
        guard let data = UserDefaults.standard.data(forKey: Self.persistKey),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else { return }
        let now = Date().timeIntervalSince1970
        for (id, entry) in stored {
            if entry.url == nil, now - entry.resolvedAt > Self.negativeTTL { continue }
            cache[id] = entry.url.flatMap(URL.init(string:))
        }
    }

    private func persistResult(stationID: String, url: URL?) {
        var stored = (UserDefaults.standard.data(forKey: Self.persistKey))
            .flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        stored[stationID] = Stored(url: url?.absoluteString, resolvedAt: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

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
        loadPersistedIfNeeded()
        if let cached = cache[stationID] { return cached }
        guard AppStorageKeys.radioLogoChainEnabledValue else { return nil }
        let resolved = await resolve(name: name, homepage: homepage)
        cache[stationID] = resolved
        persistResult(stationID: stationID, url: resolved)
        if resolved == nil {
            Logger.library.notice("RADIO logo chain: no hit for \(name, privacy: .public)")
        }
        return resolved
    }

    private func resolve(name: String, homepage: String?) async -> URL? {
        // Stage 1: Wikidata P154 — term variants (full name de/en, brand
        // stem) because the de full-name search missed real entries
        // (90s90s-Diagnose); the conservative fold-match guards each hit.
        for term in RadioLogoLookup.searchTerms(for: name) {
            for language in ["de", "en"] {
                guard let searchURL = RadioLogoLookup.wikidataSearchURL(name: term, language: language),
                      let searchData = await fetch(searchURL),
                      let entity = RadioLogoLookup.matchedEntityId(fromSearchData: searchData, stationName: name)
                else { continue }
                if let entityURL = ArtistPortraitLookup.wikidataEntityURL(entity),
                   let entityData = await fetch(entityURL),
                   let fileName = RadioLogoLookup.p154FileName(fromEntityData: entityData, entity: entity),
                   let thumb = ArtistPortraitLookup.commonsThumbURL(fileName: fileName) {
                    return thumb
                }
                break   // entity found but no P154 → deeper terms won't help this language pair
            }
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
