// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import OSLog

/// F6: THE global search — fans out over every active SearchableProvider plus
/// the "New Shows" catalog source (PodcastDirectory; NOT a provider
/// capability), debounced, cancellable, with a per-provider timeout so one
/// slow server never blocks the others. Partial results publish as they
/// arrive; per-source errors are logged (Regel 3) and a TOTAL failure is a
/// visible state, never a silent empty list.
@MainActor
final class GlobalSearchModel: ObservableObject {
    struct Section: Identifiable, Equatable {
        let kind: SearchResult.Kind
        var results: [SearchResult]
        var id: String { kind.rawValue }
    }

    @Published var query = ""
    @Published private(set) var sections: [Section] = []
    @Published private(set) var isSearching = false
    /// Every source failed or timed out — the UI shows a visible error state.
    @Published private(set) var allSourcesFailed = false

    static let debounce: Duration = .milliseconds(300)
    static let providerTimeout: Duration = .seconds(5)
    /// Minimum characters before server requests fire.
    static let minServerChars = 2

    private let providers: @MainActor () -> [any SearchableProvider]
    private let catalog: @MainActor @Sendable (String) async throws -> [SearchResult]
    /// Tests shrink the debounce to keep runs fast.
    var debounceOverride: Duration?
    private var runTask: Task<Void, Never>?

    init(providers: @escaping @MainActor () -> [any SearchableProvider],
         catalog: @escaping @MainActor @Sendable (String) async throws -> [SearchResult]) {
        self.providers = providers
        self.catalog = catalog
    }

    /// The app-wide instance: all active providers + the podcast catalog.
    static func production() -> GlobalSearchModel {
        GlobalSearchModel(
            providers: {
                AppSession.shared.allProviders.compactMap { provider in
                    guard provider.isAvailable else { return nil }
                    return provider as? any SearchableProvider
                }
            },
            catalog: { query in
                #if DEBUG
                if let seeded = UITestSeed.catalogSearchOverride {
                    return seeded(query)
                }
                #endif
                let directory: PodcastDirectory = AppStorageKeys.podcastIndexConfigured
                    ? PodcastIndexDirectory(key: AppStorageKeys.podcastIndexKeyValue,
                                            secret: AppStorageKeys.podcastIndexSecretValue)
                    : ITunesDirectory()
                let hits = try await directory.search(query)
                let subscribed = Set(
                    (PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.shows)
                        .map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
                // Already subscribed shows never appear as catalog hits.
                return PodcastRecommendationsStore
                    .excludingSubscribed(hits, subscribedNormalizedFeeds: subscribed)
                    .map { hit in
                        SearchResult(id: hit.feedURL, kind: .catalogShow, title: hit.title,
                                     subtitle: hit.author,
                                     coverURL: hit.artworkURL.flatMap { URL(string: $0) })
                    }
            })
    }

    /// Debounce + cancel-on-new-input; below the server minimum the results
    /// clear without any request.
    func queryChanged(activeTab: MediaType) {
        runTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minServerChars else {
            sections = []
            isSearching = false
            allSourcesFailed = false
            return
        }
        let delay = debounceOverride ?? Self.debounce
        runTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.run(query: trimmed, activeTab: activeTab)
        }
    }

    private func run(query: String, activeTab: MediaType) async {
        // SEARCHPROBE (device diagnosis, Such-Freeze 01.08): total wall time
        // of the fan-out — the first-query hang shows up here if a provider
        // computes on the main actor.
        let started = ContinuousClock.now
        defer {
            let ms = Int(Double((ContinuousClock.now - started).components.attoseconds) / 1e15)
            Logger.library.notice("SEARCHPROBE query len=\(query.count) ms=\(ms)")
        }
        RecentSearches.record(query)   // Y30: an executed search is a recent one
        isSearching = true
        allSourcesFailed = false
        sections = []

        var collected: [SearchResult] = []
        var sources = 0
        var failures = 0

        await withTaskGroup(of: (source: String, results: [SearchResult]?).self) { group in
            for provider in providers() {
                sources += 1
                let name = String(describing: type(of: provider))
                group.addTask {
                    let hits = await withSearchTimeout(Self.providerTimeout) {
                        try await provider.search(query: query)
                    }
                    return (name, hits)
                }
            }
            sources += 1
            let catalog = self.catalog
            group.addTask {
                let hits = await withSearchTimeout(Self.providerTimeout) {
                    try await catalog(query)
                }
                return ("catalog", hits)
            }

            // Partial results appear as each source lands.
            for await (source, results) in group {
                if Task.isCancelled { return }
                if let results {
                    collected += results
                    sections = SearchRanking.sections(results: collected, activeTab: activeTab)
                        .map { Section(kind: $0.kind, results: $0.results) }
                } else {
                    failures += 1
                    // Regel 3: a failed/timed-out source is never silent.
                    Logger.library.error("search source \(source, privacy: .public) failed or timed out for query length \(query.count)")
                }
            }
        }

        guard !Task.isCancelled else { return }
        isSearching = false
        allSourcesFailed = sources > 0 && failures == sources
    }
}
