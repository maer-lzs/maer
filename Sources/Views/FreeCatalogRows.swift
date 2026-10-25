// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import OSLog

/// The LibriVox import shows its progress where every other
/// download does. In the tile's corner slot, through the SHARED
/// `UnifiedDownloadRing`. Self-observing like `CardDownloadBadge`, so only
/// this small view re-renders per progress tick; nothing at all is drawn
/// while no import runs for THIS item (the corner slot collapses).
struct FreeCatalogImportBadge: View {
    let itemId: String
    @ObservedObject private var importer = LibriVoxImporter.shared
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 17

    var body: some View {
        if importer.activeBookId == itemId,
           let fraction = LibriVoxImporter.ringFraction(importer.phase) {
            Button { importer.cancel() } label: {
                UnifiedDownloadRing(fraction: fraction, lineWidth: 2.5, tint: .white)
                    .frame(width: ringSize, height: ringSize)
                    .padding(5)
                    .glyphDisc()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel Download"))
        }
    }
}

/// THE page of a catalogue title, opened from a tile: the same choice the
/// full player's source tap makes (`PlayerSourceTargets.catalogPage`). A
/// song opens its release, an album its album page, a reading its book
/// page. A title not started yet has no form; the surface names the one it
/// shows (`unstartedForm`), so a music surface opens an album page.
enum CatalogDetailsPage {
    static func target(itemId: String, startedForm: ProgressMark.StartedForm?,
                       unstartedForm: ProgressMark.StartedForm?) -> PlayerSourceTarget {
        PlayerSourceTargets.catalogPage(itemId, markedForm: startedForm ?? unstartedForm)
    }

    /// Pushes the page on the stack of the tab the tile stands in.
    @MainActor
    static func open(itemId: String, unstartedForm: ProgressMark.StartedForm?,
                     pushMusicRoute: (MusicRoute) -> Void,
                     pushFreeAudiobooksRoute: (FreeAudiobooksRoute) -> Void) {
        let target = target(itemId: itemId, startedForm: ListeningStore.startedForm(itemId),
                            unstartedForm: unstartedForm)
        switch target {
        case .catalogAlbum(let id): pushMusicRoute(.catalogAlbum(id))
        case .catalogBook(let id): pushFreeAudiobooksRoute(.catalogBook(itemId: id))
        default:
            // `catalogPage` names only the two catalogue pages.
            Logger.library.notice("CATALOG details without a page target=\(String(describing: target), privacy: .public)")
        }
    }
}

/// "Details" in a catalogue tile's context menu: the title's page
/// (`CatalogDetailsPage`), pushed like a tap on a tile.
struct CatalogDetailsButton: View {
    @Environment(\.pushMusicRoute) private var pushMusicRoute
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    let itemId: String
    /// Every tile that carries this button stands on a music surface.
    var unstartedForm: ProgressMark.StartedForm? = .album

    var body: some View {
        Button {
            CatalogDetailsPage.open(itemId: itemId, unstartedForm: unstartedForm,
                                    pushMusicRoute: pushMusicRoute,
                                    pushFreeAudiobooksRoute: pushFreeAudiobooksRoute)
        } label: {
            Label("Details", systemImage: "info.circle")
        }
    }
}
