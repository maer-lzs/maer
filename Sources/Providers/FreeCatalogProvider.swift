// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// 0714d26: playback resolution for the free-catalog rows — owns the
/// `lv:` (LibriVox book), `lva:` (archive.org item) and `jam:` (Jamendo
/// track) namespaces. NOT a library source: `isAvailable` stays false (no
/// tab, no search fan-out) — the Discover rows remember their items here and
/// the player routes by prefix like everywhere else.
@MainActor
final class FreeCatalogProvider: AudioProvider {
    static let shared = FreeCatalogProvider()
    private init() {}

    var providerId: String { "freecatalog" }
    var mediaType: MediaType { .audiobooks }
    var capabilities: ProviderCapabilities { [] }
    var streamAuthHeaders: [String: String] { [:] }
    /// Deliberately false — Discover-only surface, never a tab/search source.
    var isAvailable: Bool { false }

    /// Session caches the rows fill (id → source object).
    private var librivoxBooks: [String: LibriVoxBook] = [:]
    private var jamendoTracks: [String: JamendoTrack] = [:]
    private var itemsById: [String: LibraryItem] = [:]

    func remember(book: LibriVoxBook) -> LibraryItem {
        let id = FreeCatalog.librivoxPrefix + book.id
        librivoxBooks[id] = book
        // 40b8f96: LibriVox recordings are public domain — the capsule says so
        // instead of leaving the class blank where we DO know it.
        licences[id] = String(localized: "Public domain")
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: book.title, authorName: FreeCatalog.authorLine(book.authors),
                    narratorName: nil, seriesName: nil, genres: nil,
                    publishedYear: nil, description: nil),
                duration: book.totaltimesecs.map(Double.init), chapters: nil, tracks: nil),
            addedAt: nil)
        itemsById[id] = item
        return item
    }

    /// e948444: identifiers that came from the Old-Time-Radio row — they
    /// are series bundles by design and get the higher track bound.
    private var oldTimeRadioIds: Set<String> = []

    func rememberOldTimeRadio(_ identifier: String) { oldTimeRadioIds.insert(identifier) }

    /// e948444: stated licence per item id, for the detail sheet.
    private var licences: [String: String] = [:]

    func licence(forItemId id: String) -> String? { licences[id] }

    /// 0ce5df3: a Gutenberg audiobook as a library item. Non-audiobooks
    /// (music examples inside scholarly texts) are filtered by path.
    func remember(gutenberg book: GutenbergClient.Book) -> LibraryItem? {
        guard let audio = book.formats?["audio/mpeg"],
              FreeCatalog.isGutenbergAudiobook(audio) else { return nil }
        let id = FreeCatalog.gutenbergPrefix + String(book.id)
        gutenbergAudio[id] = audio
        // the owner 05.08. (Geraet): the Gutenberg tiles came up WITHOUT covers.
        // Cause: the cover url rode along in `formats` and was dropped here,
        // and `coverURL(forItemId:)` had no gut: branch at all — so every
        // Gutenberg tile fell back to the placeholder. Measured at gutendex
        // before building: 32 of 32 entries on page 1 carry an image/jpeg, and
        // the urls answer 200 image/jpeg (no hotlink block).
        gutenbergCovers[id] = FreeCatalog.gutenbergCoverURL(formats: book.formats)
        licences[id] = String(localized: "Public domain")
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: book.title ?? "—",
                    authorName: book.authors?.compactMap(\.name).first,
                    narratorName: nil, seriesName: nil, genres: nil,
                    publishedYear: nil, description: nil),
                duration: nil, chapters: nil, tracks: nil),
            addedAt: nil)
        itemsById[id] = item
        return item
    }

    private var gutenbergAudio: [String: String] = [:]
    private var gutenbergCovers: [String: URL] = [:]

    func gutenbergAudioURL(forItemId id: String) -> String? { gutenbergAudio[id] }

    func remember(popular doc: ArchivePopularDoc) -> LibraryItem? {
        guard let identifier = doc.identifier else { return nil }
        let id = FreeCatalog.archivePrefix + identifier
        if let licence = FreeCatalog.licenceLabel(doc.licenseurl) { licences[id] = licence }
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    // 3ac9183: first entry leads (composer first); the
                    // detail sheet names everyone via the joined form.
                    title: doc.title?.first, authorName: doc.creator?.first, narratorName: nil,
                    // 50aefa8: the recording year, where the index has one.
                    seriesName: nil, genres: nil,
                    publishedYear: doc.year?.first.map(LenientString.init),
                    description: nil),
                // ea6e002: the search index carries the runtime for most
                // items — the card's time line reads it from here.
                duration: FreeCatalog.runtimeSeconds(doc.runtime), chapters: nil, tracks: nil),
            addedAt: nil)
        itemsById[id] = item
        return item
    }

    func remember(track: JamendoTrack) -> LibraryItem? {
        guard let trackId = track.id else { return nil }
        let id = FreeCatalog.jamendoPrefix + trackId
        jamendoTracks[id] = track
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: track.name, authorName: track.artist_name, narratorName: nil,
                    seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: track.duration.map(Double.init), chapters: nil, tracks: nil),
            addedAt: nil)
        itemsById[id] = item
        return item
    }

    func libraryItem(forId id: String) -> LibraryItem? { itemsById[id] }
    func librivoxBook(forId id: String) -> LibriVoxBook? { librivoxBooks[id] }
    func jamendoTrack(forId id: String) -> JamendoTrack? { jamendoTracks[id] }

    // MARK: - AudioProvider

    func fetchLibraries() async throws -> [ABSLibrary] { [] }
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        if itemId.hasPrefix(FreeCatalog.librivoxPrefix) {
            guard let book = librivoxBooks[itemId] else { throw URLError(.resourceUnavailable) }
            let tracks = FreeCatalog.tracks(from: book.sections)
            guard !tracks.isEmpty else { throw URLError(.resourceUnavailable) }
            return LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(
                    metadata: LibraryItemMetadata(
                        title: book.title, authorName: FreeCatalog.authorLine(book.authors),
                        narratorName: nil, seriesName: nil, genres: nil,
                        publishedYear: nil, description: nil),
                    duration: book.totaltimesecs.map(Double.init), chapters: nil,
                    tracks: tracks),
                userMediaProgress: nil)
        }
        if itemId.hasPrefix(FreeCatalog.archivePrefix) {
            let identifier = String(itemId.dropFirst(FreeCatalog.archivePrefix.count))
            let meta = try await ArchiveOrgClient.metadata(identifier: identifier)
            let tracks = FreeCatalog.archiveTracks(identifier: identifier, files: meta.files ?? [])
            guard !tracks.isEmpty else { throw URLError(.resourceUnavailable) }
            // aed5d25 (2): plausibility gate — a collection bundle with
            // hundreds of parts is not a book; named in the log, never mute.
            // e948444: a CURATED series collection (Old Time Radio) passes the
            // higher bound — there the bundle is the unit, not an accident.
            let cap = oldTimeRadioIds.contains(identifier)
                ? FreeCatalog.seriesTrackCap : FreeCatalog.defaultTrackCap
            guard FreeCatalog.trackCountPlausible(tracks.count, cap: cap) else {
                Logger.library.notice("FREECAT gate: \(identifier, privacy: .public) dropped — \(tracks.count) tracks (collection bundle)")
                throw URLError(.resourceUnavailable)
            }
            let total = tracks.compactMap(\.duration).reduce(0, +)
            return LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(
                    metadata: LibraryItemMetadata(
                        title: meta.metadata?.title?.first ?? itemsById[itemId]?.title,
                        authorName: meta.metadata?.creator?.joined, narratorName: nil,
                        seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                    duration: total > 0 ? total : nil, chapters: nil, tracks: tracks),
                userMediaProgress: nil)
        }
        if itemId.hasPrefix(FreeCatalog.jamendoPrefix) {
            guard let track = jamendoTracks[itemId], let audio = track.audio, !audio.isEmpty else {
                throw URLError(.resourceUnavailable)
            }
            return LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(
                    metadata: LibraryItemMetadata(
                        title: track.name, authorName: track.artist_name, narratorName: nil,
                        seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                    duration: track.duration.map(Double.init), chapters: nil,
                    tracks: [ABSAudioTrack(index: 0, startOffset: 0,
                                           duration: track.duration.map(Double.init),
                                           contentUrl: audio, metadata: nil)]),
                userMediaProgress: nil)
        }
        throw URLError(.resourceUnavailable)
    }

    /// b395e5f: session cache id → hi-res cover (resolved lazily; nil result
    /// is cached too so a broken feed is fetched only once).
    private var hiresCovers: [String: URL?] = [:]

    /// b395e5f: resolve the HI-RES cover behind a LibriVox book — ONE light
    /// tag scan of the book's `url_rss` (itunes:image; no full feed parse),
    /// redirects followed by URLSession. Falls back to nil → callers keep
    /// the archive thumb; failures stay silent by spec (log only).
    func hiresCoverURL(forItemId itemId: String) async -> URL? {
        if let cached = hiresCovers[itemId] { return cached }
        guard itemId.hasPrefix(FreeCatalog.librivoxPrefix),
              let rss = librivoxBooks[itemId]?.url_rss, let url = URL(string: rss) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await RequestRetryPolicy.fetch(request)
            let resolved = FreeCatalog.extractItunesImage(data).flatMap { URL(string: $0) }
            hiresCovers[itemId] = resolved
            return resolved
        } catch {
            Logger.library.notice("FREECAT hires-cover failed (thumb stays): \(String(describing: error), privacy: .public)")
            hiresCovers[itemId] = URL?.none
            return nil
        }
    }

    func coverURL(forItemId itemId: String) -> URL? {
        if itemId.hasPrefix(FreeCatalog.librivoxPrefix) {
            guard let book = librivoxBooks[itemId],
                  let identifier = FreeCatalog.iarchiveIdentifier(from: book.url_iarchive)
            else { return nil }
            return FreeCatalog.archiveCoverURL(identifier: identifier)
        }
        if itemId.hasPrefix(FreeCatalog.archivePrefix) {
            return FreeCatalog.archiveCoverURL(
                identifier: String(itemId.dropFirst(FreeCatalog.archivePrefix.count)))
        }
        if itemId.hasPrefix(FreeCatalog.jamendoPrefix) {
            return jamendoTracks[itemId]?.image.flatMap { URL(string: $0) }
        }
        if itemId.hasPrefix(FreeCatalog.gutenbergPrefix) {
            return gutenbergCovers[itemId]
        }
        return nil
    }

    func streamURL(forContentPath contentPath: String) -> URL? { URL(string: contentPath) }

    // MARK: - ProgressSyncAPI (local-only: no server truth to sync)

    func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}

    // No bookmark capability — the empty contract shape (capability-gated).
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}
}
