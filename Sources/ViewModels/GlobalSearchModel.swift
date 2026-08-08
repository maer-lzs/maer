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
    private let catalog: @MainActor @Sendable (String, MediaType) async throws -> [SearchResult]
    /// Tests shrink the debounce to keep runs fast.
    var debounceOverride: Duration?
    private var runTask: Task<Void, Never>?

    init(providers: @escaping @MainActor () -> [any SearchableProvider],
         catalog: @escaping @MainActor @Sendable (String, MediaType) async throws -> [SearchResult]) {
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
            catalog: { query, tab in
                #if DEBUG
                if let seeded = UITestSeed.catalogSearchOverride {
                    return seeded(query)
                }
                #endif
                // Q1 (257853c): the BOOK scope asks the free CATALOGS in book
                // form — the podcast directory disappears here (LibriVox book
                // feeds are indexed there, which produced podcast rows with a
                // subscribe plus for "Struwwelpeter"). Every other scope keeps
                // the directory card unchanged (there those hits ARE shows).
                if tab == .audiobooks {
                    return await Self.catalogBookResults(query: query)
                }
                let directory: PodcastDirectory = AppStorageKeys.podcastIndexConfigured
                    ? PodcastIndexDirectory(key: AppStorageKeys.podcastIndexKeyValue,
                                            secret: AppStorageKeys.podcastIndexSecretValue)
                    : ITunesDirectory()
                let hits = try await directory.search(query)
                // fb94905 (3): SEARCH is the exception — someone typing a
                // title wants to FIND it, even when they already have it.
                // The row marks it instead (PodcastSubscribeBadge shows the
                // green check for subscribed feeds), so nothing is hidden
                // from a deliberate search. Duplicates still collapse.
                var seenFeeds = Set<String>()
                return hits
                    .filter { seenFeeds.insert(PodcastSubscriptions.normalizeFeedURL($0.feedURL)).inserted }
                    .map { hit in
                        SearchResult(id: hit.feedURL, kind: .catalogShow, title: hit.title,
                                     subtitle: hit.author,
                                     coverURL: hit.artworkURL.flatMap { URL(string: $0) })
                    }
            })
    }

    /// Q1: the free-catalog book search — the three EXISTING clients
    /// (LibriVox title API, gutendex search, archive advancedsearch with a
    /// title clause), concurrent; a failing source drops out. Gates: master
    /// plus each source's service opt-out (a source that is off contributes
    /// nothing). Results are remembered in the provider, so covers, licence
    /// capsules and the detail sheet ride the existing paths.
    @MainActor
    static func catalogBookResults(query: String) async -> [SearchResult] {
        guard UserDefaults.standard.object(forKey: AppStorageKeys.freeCatalogsMasterEnabled) as? Bool ?? true else { return [] }
        let provider = FreeCatalogProvider.shared
        let librivoxOn = UserDefaults.standard.object(forKey: AppStorageKeys.librivoxRowsEnabled) as? Bool ?? true
        let archiveOn = UserDefaults.standard.object(forKey: AppStorageKeys.archivePopularEnabled) as? Bool ?? true
        // Isolation-checker rule (same as P8): only Sendable RAW payloads
        // cross the group boundary; remember()/result building runs on the
        // main actor afterwards.
        enum RawHits: Sendable {
            case librivox([LibriVoxBook])
            case gutenberg([GutenbergClient.Book])
            case archive([ArchivePopularDoc])
        }
        let raw = await withTaskGroup(of: RawHits.self) { group in
            if librivoxOn {
                group.addTask {
                    .librivox((try? await LibriVoxClient.searchBooks(title: query)) ?? [])
                }
                group.addTask {
                    .gutenberg((try? await GutenbergClient.audiobooks(languages: [], search: query)) ?? [])
                }
            }
            if archiveOn {
                group.addTask {
                    let base = "collection:audio_bookspoetry AND NOT collection:librivoxaudio"
                        + " AND mediatype:(audio) AND licenseurl:[* TO *]"
                    return .archive((try? await ArchiveOrgClient.popular(
                        query: base + " AND title:(\(query))", rows: 10)) ?? [])
                }
            }
            var collected: [RawHits] = []
            for await hits in group { collected.append(hits) }
            return collected
        }
        var out: [SearchResult] = []
        for hits in raw {
            switch hits {
            case .librivox(let books):
                out += books.map { provider.remember(book: $0) }
                    .map { Self.bookResult($0, source: "LibriVox") }
            case .gutenberg(let books):
                out += books.compactMap { provider.remember(gutenberg: $0) }
                    .map { Self.bookResult($0, source: "Project Gutenberg") }
            case .archive(let docs):
                out += docs.filter { FreeCatalog.isCuratedArchiveDoc($0) }
                    .compactMap { provider.remember(popular: $0) }
                    .map { Self.bookResult($0, source: "Internet Archive") }
            }
        }
        return out
    }

    @MainActor
    private static func bookResult(_ item: LibraryItem, source: String) -> SearchResult {
        SearchResult(id: item.id, kind: .catalogBook, title: item.title,
                     subtitle: item.author,
                     coverURL: AppSession.shared.coverURL(forItemId: item.id),
                     sourceLabel: source)
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
                    try await catalog(query, activeTab)
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
