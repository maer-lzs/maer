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
                    return try await Self.catalogBookResults(query: query)
                }
                // The ONE directory selection. It also closes a hole this
                // site had: with Apple off and no PodcastIndex key the old
                // fallback still asked iTunes.
                guard let directory = PodcastDirectorySelection.directory() else { return [] }
                let hits = try await directory.search(query)
                // SEARCH is the exception. Someone typing a
                // title wants to FIND it, even when they already have it.
                // The row marks it instead (PodcastSubscribeBadge shows the
                // green check for subscribed feeds), so nothing is hidden
                // from a deliberate search. Duplicates still collapse.
                var seenFeeds = Set<String>()
                return hits
                    .filter { seenFeeds.insert(PodcastIdentity.normalizeFeedURL($0.feedURL)).inserted }
                    .map { hit in
                        SearchResult(id: hit.feedURL, kind: .catalogShow, title: hit.title,
                                     subtitle: hit.author,
                                     coverURL: hit.artworkURL.flatMap { URL(string: $0) })
                    }
            })
    }

    /// The free-catalog book search. The three EXISTING clients
    /// (LibriVox title API, gutendex search, archive advancedsearch with a
    /// title clause), concurrent; a failing source drops out and is logged,
    /// and when every asked source failed the search throws, so it counts
    /// as a failed source instead of an empty one. Gates: master
    /// plus each source's service opt-out (a source that is off contributes
    /// nothing). Results are remembered in the provider, so covers, licence
    /// capsules and the detail sheet ride the existing paths.
    @MainActor
    static func catalogBookResults(query: String) async throws -> [SearchResult] {
        let provider = FreeCatalogProvider.shared
        let librivoxOn = AppStorageKeys.librivoxActive
        let gutenbergOn = AppStorageKeys.gutenbergSourceActive
        let archiveOn = AppStorageKeys.archiveBooksActive
        guard librivoxOn || gutenbergOn || archiveOn else { return [] }
        // Isolation-checker rule: only Sendable RAW payloads
        // cross the group boundary; remember()/result building runs on the
        // main actor afterwards.
        enum RawHits: Sendable {
            case librivox([LibriVoxBook])
            case gutenberg([GutenbergClient.Book])
            case archive([ArchivePopularDoc])
            /// A source that did not answer, with its log reason.
            case failed(source: String, FetchAnswer<[SearchResult]>)
        }
        let raw = await withTaskGroup(of: RawHits.self) { group in
            if librivoxOn {
                group.addTask {
                    do { return .librivox(try await LibriVoxClient.searchBooks(title: query)) }
                    catch { return .failed(source: "librivox", .from(error)) }
                }
            }
            // Gutenberg used to ride the LibriVox gate. With its own source
            // switch that would be the dead-switch class: off, and the
            // request still leaves.
            if gutenbergOn {
                group.addTask {
                    do { return .gutenberg(try await GutenbergClient.audiobooks(languages: [], search: query)) }
                    catch { return .failed(source: "gutenberg", .from(error)) }
                }
            }
            if archiveOn {
                group.addTask {
                    // Third surface of the same class: search used to stand
                    // on a REBUILT base query. Now the same one truth as the
                    // row and the shelf.
                    let base = ArchiveOrgClient.archiveBaseQuery(for: .archiveBooks) ?? ""
                    do {
                        return .archive(try await ArchiveOrgClient.popular(
                            query: base + " AND title:(\(query))", rows: 10))
                    } catch {
                        return .failed(source: "archive", .from(error))
                    }
                }
            }
            var collected: [RawHits] = []
            for await hits in group { collected.append(hits) }
            return collected
        }
        var answers: [FetchAnswer<[SearchResult]>] = []
        for hits in raw {
            switch hits {
            case .librivox(let books):
                answers.append(.value(books.map { provider.remember(book: $0) }
                    .map { Self.bookResult($0, source: "LibriVox") }))
            case .gutenberg(let books):
                answers.append(.value(books.compactMap { provider.remember(gutenberg: $0) }
                    .map { Self.bookResult($0, source: "Project Gutenberg") }))
            case .archive(let docs):
                answers.append(.value(docs.filter { FreeCatalog.isCuratedArchiveDoc($0) }
                    .compactMap { provider.remember(popular: $0) }
                    .map { Self.bookResult($0, source: "Internet Archive") }))
            case .failed(let source, let answer):
                if case .failed(let reason) = answer {
                    Logger.library.error("FETCH failed what=catalog search source=\(source, privacy: .public) reason=\(reason, privacy: .public)")
                }
                answers.append(answer)
            }
        }
        return try FetchAnswer.joined(answers).get()
    }

    /// `readingVersion` answers from the catalogue's register by default; a
    /// witness hands in its own.
    @MainActor
    static func bookResult(_ item: LibraryItem, source: String,
                           readingVersion: (String) -> Int? = {
                               FreeCatalogProvider.shared.readingVersion(forItemId: $0)
                           }) -> SearchResult {
        // Measured: single works exist several times on LibriVox (two German
        // and two English readings of the same title). Title normalisation
        // lifts the `(version 2)` out, otherwise four identical rows would
        // stand here, so the reading number belongs visibly in the row.
        var subtitle = item.author
        if let version = readingVersion(item.id) {
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
        RecentSearches.record(query)   // an executed search is a recent one
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
                    sections = SearchRanking.sections(results: collected, query: query,
                                                      activeTab: activeTab,
                                                      startedIds: Self.startedIds(among: collected))
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

        // ONE measuring line per finished search. The query itself never
        // appears: it is the person's own text. Its LENGTH is enough to
        // tell a two-letter probe from a real search.
        let ranked = SearchRanking.ranked(results: collected, query: query, activeTab: activeTab,
                                          startedIds: Self.startedIds(among: collected))
        let scope = SearchScope.initial(for: activeTab).rawValue
        let top = ranked.first?.result.kind.rawValue ?? "none"
        Logger.library.info("SEARCH ranked query=\(query.count, privacy: .public) scopes=\(scope, privacy: .public) hits=\(collected.count, privacy: .public) sections=\(self.sections.count, privacy: .public) top=\(top, privacy: .public)")
        #if DEBUG
        // The three best with their reasons, so a wrong order can be read
        // instead of guessed. Kinds and reasons only, never titles.
        for hit in ranked.prefix(3) {
            Logger.library.debug("SEARCH top kind=\(hit.result.kind.rawValue, privacy: .public) tier=\(hit.score.tier, privacy: .public) points=\(hit.score.points, privacy: .public) why=\(hit.reasons.map(\.rawValue).joined(separator: "+"), privacy: .public)")
        }
        #endif
    }

    /// The hits the person already has a position in. Read per hit
    /// because a search shows a few dozen, and the store answers from
    /// the defaults dictionary it holds anyway; a whole scan of every
    /// listened item would cost far more than it saves.
    private static func startedIds(among results: [SearchResult]) -> Set<String> {
        var out: Set<String> = []
        for result in results where !result.id.isEmpty {
            guard let stored = ListeningStore.backup(result.id), let position = stored.first,
                  position > 0 else { continue }
            out.insert(result.id)
        }
        return out
    }
}
