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
    /// into a sentence on the surface.
    static func quickMetadata(forItemId itemId: String) async -> Answer {
        guard itemId.hasPrefix(FreeCatalog.archivePrefix) else { return .none }
        let identifier = FreeCatalog.archiveIdentifier(of: itemId) ?? itemId
        do {
            guard let meta = try await ArchiveOrgClient.metadataOnly(identifier: identifier) else { return .none }
            return .found(meta)
        } catch {
            guard !error.isCancellation else { return .cancelled }
            let reason = FreeCatalog.failureReason(error) ?? FailureReason.of(error)
            Logger.library.notice("FREECAT metadataOnly id=\(identifier, privacy: .public) FAILED: \(reason, privacy: .public)")
            return .failed(reason: reason)
        }
    }
}
