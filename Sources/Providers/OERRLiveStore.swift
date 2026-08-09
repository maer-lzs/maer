// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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

    /// Befund Y (Y1): the ONE surface entry point — live for OERR, pure
    /// curation data otherwise. The dependency arrow points store → data;
    /// the Models layer never touches this type.
    static func feeds(for source: CatalogSource, languages: [String]) -> [HoerspielCuration.Entry] {
        source == .oerr
            ? shared.current(forLanguages: languages)
            : source.curatedFeeds(forLanguages: languages)
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
                  let languageTerm = OERRCuration.searchTerms[language] else { continue }
            // L2 (gemessen): der Sprach-Begriff findet in au/ca/nz nur die
            // BBC — die dortigen Anstalten brauchen eigene Begriffe. Der
            // Sprach-Begriff bleibt als Grundlage, die Anstalts-Begriffe
            // kommen dazu (Anstalten OHNE eigene Begriffe aendern sich nicht).
            var terms = [languageTerm]
            for broadcaster in active where broadcaster.storefront == storefront {
                terms += broadcaster.searchTerms
            }
            var hits: [PodcastSearchResult] = []
            var seenHits = Set<String>()
            for term in terms {
                let found = (try? await ITunesDirectory().search(term, country: storefront)) ?? []
                for hit in found where seenHits.insert(hit.feedURL).inserted { hits.append(hit) }
            }
            var accepted = 0
            for hit in hits {
                guard let broadcaster = OERRCuration.matches(artistName: hit.author) else { continue }
                // L2: sender AND form. Without the form gate the broadcaster's
                // news would stand in a radio-play row (measured).
                guard OERRCuration.isFiction(categories: hit.categories) else { continue }
                let normalized = PodcastSubscriptions.normalizeFeedURL(hit.feedURL)
                guard seenFeeds.insert(normalized).inserted else { continue }
                merged.append(HoerspielCuration.Entry(
                    title: hit.title, author: hit.author ?? "",
                    feedURL: hit.feedURL,
                    language: broadcaster.language == "de" ? nil : broadcaster.language,
                    group: .oerr, country: broadcaster.country,
                    artworkURL: hit.artworkURL))
                accepted += 1
            }
            Logger.rss.notice("OERR live storefront=\(storefront, privacy: .public) terms=\(terms.count) hits=\(hits.count) accepted=\(accepted)")
        }
        loaded = merged.count > seed.count
        let result = merged
        BottomBarState.shared.runWhenCalm { [weak self] in self?.entries = result }
    }
}
