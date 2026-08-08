// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import OSLog

/// X²·3: the public-broadcast row loads LIVE — the positive-list rule
/// (`OERRCuration`) applied to the Apple directory via the existing search
/// client, one query per active language in its broadcasters' storefronts.
/// The hand-curated `HoerspielCuration` OERR entries are the SEED and the
/// offline/failure fallback — never less than today. Applies calm-gated;
/// once per session, healed on connectivity like the catalog stores.
@MainActor
final class OERRLiveStore: ObservableObject {
    static let shared = OERRLiveStore()

    /// Seed first (the familiar tiles keep their spots), live additions after.
    @Published private(set) var entries: [HoerspielCuration.Entry] = []
    private var loaded = false
    private var loading = false

    private init() {}

    /// The current row content — seed synchronously when nothing loaded yet.
    func current(forLanguages codes: [String]) -> [HoerspielCuration.Entry] {
        let base = entries.isEmpty
            ? HoerspielCuration.feeds(forLanguages: codes).filter { $0.group == .oerr }
            : entries
        return base.filter { entry in
            guard let language = entry.language else { return true }
            return codes.contains(language)
        }
    }

    func ensureLoaded(forLanguages codes: [String]) async {
        guard !loaded, !loading, NetworkMonitor.shared.isConnected else { return }
        #if DEBUG
        if UITestSeed.isActive { return }   // seed-only in the harness
        #endif
        loading = true
        defer { loading = false }

        let seed = HoerspielCuration.feeds(forLanguages: ["de", "en", "fr", "it", "es",
                                                          "nl", "sv", "no", "da", "fi",
                                                          "pt", "ja", "ko"])
            .filter { $0.group == .oerr }
        var merged = seed
        var seenFeeds = Set(seed.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })

        // One query per active language, in each of its storefronts.
        let active = OERRCuration.active(forLanguages: codes)
        let storefronts = Set(active.map(\.storefront))
        for storefront in storefronts {
            guard let language = active.first(where: { $0.storefront == storefront })?.language,
                  let term = OERRCuration.searchTerms[language] else { continue }
            let hits = (try? await ITunesDirectory().search(term, country: storefront)) ?? []
            var accepted = 0
            for hit in hits {
                guard let broadcaster = OERRCuration.matches(artistName: hit.author) else { continue }
                let normalized = PodcastSubscriptions.normalizeFeedURL(hit.feedURL)
                guard seenFeeds.insert(normalized).inserted else { continue }
                merged.append(HoerspielCuration.Entry(
                    title: hit.title, author: hit.author ?? "",
                    feedURL: hit.feedURL,
                    language: broadcaster.language == "de" ? nil : broadcaster.language,
                    group: .oerr, country: broadcaster.country))
                accepted += 1
            }
            Logger.rss.notice("OERR live storefront=\(storefront, privacy: .public) hits=\(hits.count) accepted=\(accepted)")
        }
        loaded = merged.count > seed.count
        let result = merged
        BottomBarState.shared.runWhenCalm { [weak self] in self?.entries = result }
    }
}
