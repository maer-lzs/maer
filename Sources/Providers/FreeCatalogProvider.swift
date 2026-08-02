// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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

    func remember(popular doc: ArchivePopularDoc) -> LibraryItem? {
        guard let identifier = doc.identifier else { return nil }
        let id = FreeCatalog.archivePrefix + identifier
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: doc.title, authorName: doc.creator, narratorName: nil,
                    seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: nil, chapters: nil, tracks: nil),
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
            let total = tracks.compactMap(\.duration).reduce(0, +)
            return LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(
                    metadata: LibraryItemMetadata(
                        title: meta.metadata?.title ?? itemsById[itemId]?.title,
                        authorName: meta.metadata?.creator, narratorName: nil,
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
