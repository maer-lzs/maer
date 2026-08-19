// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// A "Listen Again" tile for a catalogue title that was started as an album
/// track. Shares the album tile, so the mixed row keeps ONE density — a row
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

    var body: some View {
        if let item = resolved ?? AppSession.shared.libraryItem(forId: itemId) {
            AlbumCell(item: item, width: width, playerCoordinator: playerCoordinator)
                .frame(width: width, alignment: .top)
        } else if let stub = AppSession.shared.playableItem(forId: itemId) {
            AlbumCell(item: stub, width: width, playerCoordinator: playerCoordinator)
                .frame(width: width, alignment: .top)
                .task {
                    // Fills the provider's session cache; the local state then
                    // re-renders this tile with what the detail knows.
                    _ = try? await FreeCatalogProvider.shared.fetchItemDetail(itemId: itemId)
                    resolved = AppSession.shared.libraryItem(forId: itemId)
                }
        }
    }
}
