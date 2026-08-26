// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// THE global search. Fans out over every active SearchableProvider plus
/// the "New Shows" catalog source (PodcastDirectory; NOT a provider
/// capability), debounced, cancellable, with a per-provider timeout so one
/// slow server never blocks the others. Partial results publish as they
/// arrive; per-source errors are logged and a TOTAL failure is a
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
    /// Every source failed or timed out. The UI shows a visible error state.
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
                // The BOOK scope asks the free CATALOGS in book
                // form. The podcast directory disappears here (LibriVox book
                // feeds are indexed there, which produced podcast rows with a
                // subscribe plus for "Struwwelpeter"). Every other scope keeps
                // the directory card unchanged (there those hits ARE shows).
                if tab == .audiobooks {
                    return await Self.catalogBookResults(query: query)
                }
                let directory: PodcastDirectory = AppStorageKeys.podcastIndexConfigured
                    ? PodcastIndexDirectory(key: AppStorageKeys.podcastIndexEffectiveKey,
                                            secret: AppStorageKeys.podcastIndexEffectiveSecret)
                    : ITunesDirectory()
                let hits = try await directory.search(query)
                // SEARCH is the exception. Someone typing a
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

    /// The free-catalog book search. The three EXISTING clients
    /// (LibriVox title API, gutendex search, archive advancedsearch with a
    /// title clause), concurrent; a failing source drops out. Gates: master
    /// plus each source's service opt-out (a source that is off contributes
    /// nothing). Results are remembered in the provider, so covers, licence
    /// capsules and the detail sheet ride the existing paths.
    @MainActor
    static func catalogBookResults(query: String) async -> [SearchResult] {
        guard AppStorageKeys.freeCatalogsMasterActive else { return [] }
        let provider = FreeCatalogProvider.shared
        let librivoxOn = AppStorageKeys.librivoxActive
        let archiveOn = AppStorageKeys.archiveBooksActive
        // Isolation-checker rule: only Sendable RAW payloads
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
                    // Third surface of the same class: the
                    // Suche stand auf einer NACHGEBAUTEN Basis. Jetzt dieselbe
                    // eine Wahrheit wie Reihe und Regal.
                    let base = ArchiveOrgClient.archiveBaseQuery(for: .archiveBooks) ?? ""
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
        // Gemessen: einzelne Werke liegen bei LibriVox mehrfach vor (zwei
        // deutsche, zwei englische Lesungen desselben Titels). Die
        // Titel-Normalisierung hebt das `(version 2)` heraus, sonst stuenden
        // hier vier identische Zeilen; die Lesungs-Nummer gehoert deshalb
        // sichtbar in die Zeile.
        var subtitle = item.author
        if let version = FreeCatalogProvider.shared.readingVersion(forItemId: item.id) {
            let reading = String(localized: "Reading \(version)")
            subtitle = [item.author, reading].compactMap { $0 }.joined(separator: " · ")
        }
        return SearchResult(id: item.id, kind: .catalogBook, title: item.title,
                            subtitle: subtitle,
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
                    // A failed/timed-out source is never silent.
                    Logger.library.error("search source \(source, privacy: .public) failed or timed out for query length \(query.count)")
                }
            }
        }

        guard !Task.isCancelled else { return }
        isSearching = false
        allSourcesFailed = sources > 0 && failures == sources
    }
}
