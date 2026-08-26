// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// A "Listen Again" tile for a catalogue title that was started as an album
/// track. Shares the album tile, so the mixed row keeps ONE density. A row
/// with two tile sizes reads as torn.
///
/// A cache miss must not blank the tile: the catalogue id is self-describing,
/// so after a cold start the cell fetches its own detail and re-renders with
/// the real title. That rule already existed for the queue row; it lives here
/// once instead of in every surface that shows a catalogue id.
struct CatalogTrackCell: View {
    let itemId: String
    let width: CGFloat
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var resolved: LibraryItem?
    /// A placeholder is a TRANSITION, not an end state. The counter lets the
    /// resolution run again the next time the cell appears. Before, `try?`
    /// swallowed the failure, there was no second attempt and no visible
    /// state, and the tile carried the placeholder name permanently.
    @State private var attempt = 0

    /// Fetches the name afterwards. A transport error is something other
    /// than a clear gone: the first leaves the entry standing and is
    /// repeated, the second marks the item as dead so the row skips it. The
    /// POSITION stays in both cases, because it belongs to the user. The tile
    /// may disappear, the entry may not.
    private func resolve() async {
        do {
            _ = try await FreeCatalogProvider.shared.fetchItemDetail(itemId: itemId)
            resolved = AppSession.shared.libraryItem(forId: itemId)
        } catch {
            guard let reason = FreeCatalog.failureReason(error) else { return }
            if FreeCatalog.isGone(error) {
                DeadCatalogItems.note(.dead, for: itemId)
                Logger.library.notice("FREECAT resolve \(itemId, privacy: .public) → weg: \(reason, privacy: .public)")
            } else {
                Logger.library.error("FREECAT resolve \(itemId, privacy: .public) FAILED: \(reason, privacy: .public)")
            }
        }
    }

    var body: some View {
        if let item = resolved ?? AppSession.shared.libraryItem(forId: itemId) {
            AlbumCell(item: item, width: width, playerCoordinator: playerCoordinator)
                .frame(width: width, alignment: .top)
        } else if let stub = AppSession.shared.playableItem(forId: itemId) {
            AlbumCell(item: stub, width: width, playerCoordinator: playerCoordinator)
                .frame(width: width, alignment: .top)
                .task(id: attempt) { await resolve() }
        }
    }
}
