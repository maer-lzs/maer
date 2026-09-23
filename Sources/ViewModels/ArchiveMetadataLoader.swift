// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The cheap metadata of an archive item (title, creator, description from
/// the sub-path, 8.3 kB instead of 1.36 MB), below the views. Two surfaces
/// asked the archive for it themselves and swallowed a failure without a
/// word; this is the one question, and its failure is an answer with a
/// reason in the log.
@MainActor
enum ArchiveMetadataLoader {
    enum Answer {
        case found(ArchiveOrgClient.MetadataResponse.Meta)
        /// Not an archive item, or the archive has no metadata for it.
        case none
        case failed(reason: String)
        case cancelled
    }

    /// Neither caller carries the page on this answer: the detail page loads
    /// the full detail beside it, the detail sheet shows the item without a
    /// description. So a failure is logged with its reason and not turned
    /// into a sentence on the surface. `clients` are the live ones by
    /// default; a witness hands in its own.
    static func quickMetadata(forItemId itemId: String, using clients: CatalogClients = .live) async -> Answer {
        guard itemId.hasPrefix(FreeCatalog.archivePrefix) else { return .none }
        let identifier = FreeCatalog.archiveIdentifier(of: itemId) ?? itemId
        do {
            guard let meta = try await clients.archive.metadataOnly(identifier) else { return .none }
            return .found(meta)
        } catch {
            guard !error.isCancellation else { return .cancelled }
            let reason = CatalogLoadOutcome.reason(error)
            Logger.library.notice("FREECAT metadataOnly id=\(identifier, privacy: .public) FAILED: \(reason, privacy: .public)")
            return .failed(reason: reason)
        }
    }

    /// After an item's detail failed: is the item WITHDRAWN, or was the
    /// service just unreachable? Told apart by measuring with the one
    /// existing ladder, and the answer is noted for the rows that skip dead
    /// items. Only a reachable service that answers error or 404 for the
    /// item means gone; a network failure says nothing about the item and
    /// keeps the retry path. Only archive items can be told apart.
    /// `defaults` is where the mark lands, so a witness can keep it out of
    /// the app's own store.
    static func isWithdrawn(itemId: String, using clients: CatalogClients = .live,
                            defaults: UserDefaults = .standard) async -> Bool {
        guard itemId.hasPrefix(FreeCatalog.archivePrefix) else { return false }
        let identifier = FreeCatalog.archiveIdentifier(of: itemId) ?? itemId
        let liveness = await clients.archive.liveness(identifier)
        DeadCatalogItems.note(liveness, for: itemId, defaults: defaults)
        return liveness == .dead
    }
}
