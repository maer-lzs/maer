// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The paged lists of the archive music pages, below the views: it asks the
/// archive, maps each record into the catalogue's register and hands back an
/// answer, a failure included.
@MainActor
enum ArchiveMusicLoader {
    typealias Outcome = CatalogLoadOutcome

    /// The catalogue the loader registers in and asks for songs.
    private static var catalog: FreeCatalogProvider { .shared }

    /// One page of an area's popularity list. `clients` are the live ones by
    /// default; a witness hands in its own.
    static func areaPage(_ area: ArchiveMusicArea, rows: Int, page: Int,
                         using clients: CatalogClients = .live) async -> Outcome {
        do {
            let docs = try await clients.archive.popularMusic(area, rows, page)
            Logger.library.notice("FREECAT \(area.key, privacy: .public) page=\(page) loaded=\(docs.count)")
            return .loaded(items: register(docs), fetched: docs.count)
        } catch {
            guard !error.isCancellation else { return .cancelled }
            Logger.library.error("FREECAT \(area.key, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
            return .failed(reason: reason(error))
        }
    }

    /// One page of a genre shelf inside an area. A shelf without subject
    /// terms has nothing to ask and answers empty, which ends its list.
    static func shelfPage(_ area: ArchiveMusicArea, shelfKey: String, rows: Int, page: Int,
                          using clients: CatalogClients = .live) async -> Outcome {
        let terms = CatalogGenreAxis.musicSubjects(forShelf: shelfKey)
        guard !terms.isEmpty else { return .loaded(items: [], fetched: 0) }
        let clause = terms.map { "subject:\"\($0)\"" }.joined(separator: " OR ")
        do {
            let docs = try await clients.archive.popularArchiveMusic("\(area.query) AND (\(clause))", rows, page)
            return .loaded(items: register(docs), fetched: docs.count)
        } catch {
            guard !error.isCancellation else { return .cancelled }
            Logger.library.error("FREECAT shelf=\(shelfKey, privacy: .public) area=\(area.key, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
            return .failed(reason: reason(error))
        }
    }

    /// A release's songs as the items they are (`CatalogSongID`), in order,
    /// from the catalogue's one list of them. The songs that did not resolve
    /// are counted for the page and named in the log.
    static func albumSongs(albumId: String, count: Int) async -> (songs: [LibraryItem], missing: Int) {
        let answer = await catalog.albumSongs(albumId: albumId, count: count)
        if let first = answer.missing.first {
            Logger.library.notice("CATALOG album songs missing=\(answer.missing.count) of=\(count) first=\(first) ns=\(ItemNamespace.of(albumId) ?? "-", privacy: .public)")
        }
        return (answer.songs, answer.missing.count)
    }

    /// The same songs where the caller does not know how many there are (a
    /// tile's long-press Shuffle): one answer of the release counts and
    /// builds them (`FreeCatalogProvider.releaseSongs`). With no songs the
    /// caller plays the release as its one title
    /// (`CatalogShuffleSongs.songs(of:)`). `metadata`: the answer, a
    /// witness hands in its own.
    static func albumSongs(albumId: String,
                           metadata: ((String) async throws -> ArchiveDecoder.MetadataResponse)? = nil)
        async -> [LibraryItem] {
        await catalog.releaseSongs(albumId: albumId, metadata: metadata)
    }

    private static func register(_ docs: [ArchivePopularDoc]) -> [LibraryItem] {
        let provider = catalog
        return docs.compactMap { provider.remember(popular: $0) }
    }

    nonisolated private static func reason(_ error: Error) -> String { Outcome.reason(error) }
}
