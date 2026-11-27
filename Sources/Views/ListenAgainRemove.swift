// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The tile of "Listen Again" a long-press menu belongs to: its id and the
/// moment it stands by.
struct ListenAgainTile: Equatable {
    let id: String
    let momentMs: Double
}

extension EnvironmentValues {
    /// The tile of "Listen Again" the menu reaches; nil outside that row.
    @Entry var listenAgainTile: ListenAgainTile? = nil
}

/// "Remove from Listen Again" for a playlist tile of that row: the marker
/// the Continue cards use, set at the tile's moment, so a newer moment
/// brings it back. The tile's own long-press menu carries the entry
/// (`ListenAgainRemoveButton` in `CollectionMenuItems`).
struct ListenAgainRemove: ViewModifier {
    /// The tile, or nil where the row offers no remove (an album).
    let tile: ListenAgainTile?

    func body(content: Content) -> some View {
        content.environment(\.listenAgainTile, tile)
    }
}

/// The menu entry, where a tile of "Listen Again" offers it.
struct ListenAgainRemoveButton: View {
    @Environment(\.listenAgainTile) private var tile

    var body: some View {
        if let tile {
            Button(role: .destructive) {
                ContinueHiddenStore.hide(id: tile.id, lastUpdate: tile.momentMs)
            } label: { Label("Remove from Listen Again", systemImage: "minus.circle") }
            .accessibilityIdentifier("remove-from-listen-again")
        }
    }
}
