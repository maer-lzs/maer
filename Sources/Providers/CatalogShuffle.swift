// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Shuffle play on a music catalog row or a shelf, drawing from the WHOLE
/// shelf rather than from the twelve visible tiles. A shelf holds several
/// thousand recordings; drawing from the preview would always yield the same
/// ones.
///
/// Two measurements decide the shape:
///  * archive.org supports `sort=random`, but **not per call**: three quick
///    repetitions return identical titles (caching), different ones only
///    after some minutes. Different PAGES return different titles at once.
///    Hence random sort AND a random page, so every tap differs instead of
///    every tenth.
///  * Jamendo does NOT know `order=random` (`status=failed`), so there the
///    draw runs over a random `offset`. Named honestly rather than claimed.
///
/// The rest of the draw is CONTEXT, never the queue: since orders and
/// context split, a shuffle hands its tail to the collection-start path
/// (the hand-placed orders survive, and the tail dies with the next
/// start). Appending to the queue was the pre-split form and would bury
/// the user's own plan under twelve drawn titles.
@MainActor
enum CatalogShuffle {
    /// How many titles one shuffle pulls (the first plays, the rest queue).
    static let batch = 12

    /// Deepest page the draw may reach: the whole stock as far as the
    /// search hands it out, not a window. This is the "anything at all"
    /// gesture, in deliberate contrast to the row's daily rotation inside
    /// the top tenth.
    static func maxPage(total: Int, rows: Int, reach: Int = ArchiveDecoder.deepPagingLimit) -> Int {
        let reachable = min(total, reach)
        guard reachable > rows, rows > 0 else { return 1 }
        return max(1, reachable / rows)
    }

    /// Draw from an archive.org area and start playing.
    static func play(area: ArchiveMusicArea, coordinator: PlayerCoordinator) async {
        let page = Int.random(in: 1...maxPage(total: area.measuredTotal, rows: batch))
        do {
            let docs = try await ArchiveOrgClient.popular(
                query: area.query, rows: batch, page: page, sort: "random")
            let items = docs.filter { FreeCatalog.isCuratedArchiveDoc($0) }
                .compactMap { FreeCatalogProvider.shared.remember(popular: $0) }
            Logger.library.notice("SHUFFLE area=\(area.key, privacy: .public) page=\(page) got=\(items.count)")
            await start(items, coordinator: coordinator, sourceTitle: area.title)
        } catch {
            Logger.library.error("SHUFFLE area=\(area.key, privacy: .public) page=\(page) FAILED: \(FailureReason.of(error), privacy: .public)")
            sayFailure(ErrorSentence.of(error), coordinator: coordinator, title: area.title)
        }
    }

    /// Draw from Jamendo (no random order there. Random offset instead).
    static func playJamendo(tags: [String] = [], coordinator: PlayerCoordinator) async {
        let offset = Int.random(in: 0..<600)
        do {
            let tracks = try await JamendoClient.popularTracks(limit: batch, tags: tags, offset: offset)
            let items = tracks.compactMap { FreeCatalogProvider.shared.remember(track: $0) }
            Logger.library.notice("SHUFFLE jamendo offset=\(offset) got=\(items.count)")
            await start(items, coordinator: coordinator,
                        sourceTitle: String(localized: "Music (Jamendo)"))
        } catch {
            Logger.library.error("SHUFFLE jamendo FAILED: \(FailureReason.of(error), privacy: .public)")
            sayFailure(ErrorSentence.of(error), coordinator: coordinator,
                       title: String(localized: "Music (Jamendo)"))
        }
    }

    /// The stock behind each book query, learned from the first answer of
    /// a session, so later draws need one request instead of two.
    private static var bookTotals: [String: Int] = [:]

    /// The archive.org query a book draw asks: the source's one base query,
    /// in the listener's languages where the source is read in several
    /// (LibriVox, the archive audiobooks). Old Time Radio is drawn whole,
    /// like its rows. Nil for a source that is not on archive.org.
    nonisolated static func bookQuery(for source: CatalogSource, languageCodes: [String]) -> String? {
        guard let base = ArchiveOrgClient.archiveBaseQuery(for: source) else { return nil }
        guard source != .oldTimeRadio,
              let clause = FreeCatalog.archiveLanguageClause(codes: languageCodes) else { return base }
        return base + " AND " + clause
    }

    /// Draw ONE title from a book catalogue and start it as a book: a work
    /// in parts is a long listen, so the draw hands no context of further
    /// books along. Archive sources draw a random page within the search's
    /// reach (`maxPage`); Gutenberg, which has no random order, a random
    /// page of its audiobook list.
    static func playBook(source: CatalogSource, coordinator: PlayerCoordinator) async {
        do {
            let items = try await drawBooks(source: source, languageCodes: SuggestionLanguages.current())
            Logger.library.notice("SHUFFLE books source=\(source.rawValue, privacy: .public) got=\(items.count)")
            guard let pick = items.randomElement() else {
                sayFailure(String(localized: "Shuffle found nothing to play this time. Please try again."),
                           coordinator: coordinator, title: source.title)
                return
            }
            await coordinator.open(item: pick)
        } catch {
            guard !error.isCancellation else { return }
            Logger.library.error("SHUFFLE books source=\(source.rawValue, privacy: .public) FAILED: \(FailureReason.of(error), privacy: .public)")
            sayFailure(ErrorSentence.of(error), coordinator: coordinator, title: source.title)
        }
    }

    /// The titles of one drawn page. A language that carries nothing falls
    /// back to the whole source, as the rows do.
    private static func drawBooks(source: CatalogSource, languageCodes: [String]) async throws -> [LibraryItem] {
        if source == .gutenberg {
            return try await drawGutenberg(languageCodes: languageCodes)
        }
        guard let filtered = bookQuery(for: source, languageCodes: languageCodes) else { return [] }
        let items = try await drawArchive(query: filtered, source: source)
        guard items.isEmpty, let whole = bookQuery(for: source, languageCodes: []), whole != filtered else { return items }
        return try await drawArchive(query: whole, source: source)
    }

    private static func drawArchive(query: String, source: CatalogSource) async throws -> [LibraryItem] {
        var total = bookTotals[query]
        if total == nil {
            let first = try await ArchiveOrgClient.popularWithTotal(query: query, rows: batch, page: 1, sort: "random")
            total = first.total ?? 0
            bookTotals[query] = total
            if maxPage(total: total ?? 0, rows: batch) == 1 {
                return CatalogShelfEntries.books(first.docs, source: source)
            }
        }
        let page = Int.random(in: 1...maxPage(total: total ?? 0, rows: batch))
        let docs = try await ArchiveOrgClient.popular(query: query, rows: batch, page: page, sort: "random")
        return CatalogShelfEntries.books(docs, source: source)
    }

    /// gutendex answers 32 titles a page.
    private static let gutenbergPageSize = 32

    /// The language sets whose Gutenberg list was empty; their draw asks
    /// the whole list.
    private static var gutenbergWithoutLanguage: Set<String> = []

    private static func drawGutenberg(languageCodes: [String]) async throws -> [LibraryItem] {
        let key = "gutenberg:" + languageCodes.joined(separator: ",")
        var codes = gutenbergWithoutLanguage.contains(key) ? [] : languageCodes
        var total = bookTotals[key]
        if total == nil {
            var first = try await GutenbergClient.audiobooksWithTotal(languages: codes, page: 1)
            if first.books.isEmpty, !codes.isEmpty {
                codes = []
                gutenbergWithoutLanguage.insert(key)
                first = try await GutenbergClient.audiobooksWithTotal(languages: codes, page: 1)
            }
            total = first.total ?? first.books.count
            bookTotals[key] = total
            if (total ?? 0) <= gutenbergPageSize { return CatalogShelfEntries.books(first.books) }
        }
        let pages = max(1, ((total ?? 0) + gutenbergPageSize - 1) / gutenbergPageSize)
        let books = try await GutenbergClient.audiobooks(languages: codes, page: Int.random(in: 1...pages))
        return CatalogShelfEntries.books(books)
    }

    /// First one plays, the rest become the CONTEXT (the collection-start
    /// path); hand-placed orders in the queue keep their right of way. A
    /// draw without a playable title says so instead of doing nothing.
    private static func start(_ items: [LibraryItem], coordinator: PlayerCoordinator,
                              sourceTitle: String) async {
        guard !items.isEmpty else {
            sayFailure(String(localized: "Shuffle found nothing to play this time. Please try again."),
                       coordinator: coordinator, title: sourceTitle)
            return
        }
        await coordinator.playInOrder(items: items,
                                      contextSource: sourceTitle)
    }

    /// A shuffle that starts nothing says why in the notice channel, like
    /// any tap that opens nothing.
    private static func sayFailure(_ sentence: String, coordinator: PlayerCoordinator, title: String) {
        coordinator.sayOpenFailure(sentence, cause: .server, title: title)
    }
}

/// The form is DATA-DRIVEN, not decided per collection. Measured on real
/// entries: netlabels 4 to 79 tracks, shellac jazz 36, classical 1. A rule
/// per surface would therefore be wrong. The answer decides.
///
/// The detail answer is fetched on tap anyway (without it there is no
/// playback address), and it carries the track count:
///  * **one track → play at once**, so a three-minute piece just starts,
///  * **several tracks → album page** with a track list; a tap there plays
///    THAT track, over the same offset path as the OTR bundles.
///
/// No guessing, no per-collection special case, no second load path.
@MainActor
enum CatalogTap {
    /// `router` answers the item's source; the live one by default.
    static func open(item: LibraryItem,
                     coordinator: PlayerCoordinator,
                     pushMusicRoute: @MainActor (MusicRoute) -> Void,
                     router: ItemRouter = .live) async {
        let count = (try? await router.provider(item.id).fetchItemDetail(itemId: item.id))?
            .media.tracks?.count ?? 1
        if count > 1 {
            pushMusicRoute(.catalogAlbum(item.id))
        } else {
            await coordinator.open(item: item)
        }
    }
}
