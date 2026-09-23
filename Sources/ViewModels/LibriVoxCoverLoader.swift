// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The hi-res cover behind a LibriVox book, below the views. One light tag
/// scan of the book's feed (`itunes:image`, no full feed parse). It was a
/// network question the catalogue's register asked on behalf of a view; the
/// register now only answers what it holds, and this loader asks the net.
@MainActor
enum LibriVoxCoverLoader {
    /// Resolved per session, a nil answer too, so a broken feed is fetched
    /// only once.
    private static var resolved: [String: URL?] = [:]

    /// The hi-res cover, or nil (callers keep the archive thumb). A failure
    /// stays silent by design and is logged. `clients` and `book` are the
    /// live ones by default; a witness hands in its own.
    static func hiresCover(forItemId itemId: String, using clients: CatalogClients = .live,
                           book: (String) -> LibriVoxBook? = {
                               FreeCatalogProvider.shared.librivoxBook(forId: $0)
                           }) async -> URL? {
        if let cached = resolved[itemId] { return cached }
        guard itemId.hasPrefix(FreeCatalog.librivoxPrefix),
              let rss = book(itemId)?.url_rss, let url = URL(string: rss) else {
            return nil
        }
        do {
            let data = try await clients.librivox.rssFeed(url)
            let found = FreeCatalog.extractItunesImage(data).flatMap { URL(string: $0) }
            resolved[itemId] = found
            return found
        } catch {
            Logger.library.notice("FREECAT hires-cover failed (thumb stays): \(String(describing: error), privacy: .public)")
            resolved[itemId] = URL?.none
            return nil
        }
    }

    /// The cover that goes with an upload: the hi-res one, else the thumb
    /// the app shows.
    static func uploadCover(forItemId itemId: String, using clients: CatalogClients = .live,
                            book: (String) -> LibriVoxBook? = {
                                FreeCatalogProvider.shared.librivoxBook(forId: $0)
                            },
                            thumb: (String) -> URL? = {
                                FreeCatalogProvider.shared.coverURL(forItemId: $0)
                            }) async -> URL? {
        if let hires = await hiresCover(forItemId: itemId, using: clients, book: book) { return hires }
        return thumb(itemId)
    }
}
