// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

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
    /// Ein Platzhalter ist ein UEBERGANG, kein Endzustand. Der Zaehler
    /// laesst die Aufloesung beim naechsten Erscheinen der Zelle erneut
    /// laufen — vorher verschluckte `try?` den Fehlschlag, es gab keinen
    /// zweiten Anlauf und keinen sichtbaren Zustand, und die Kachel trug
    /// dauerhaft den Platzhalternamen.
    @State private var attempt = 0

    /// Holt den Namen nach. Ein Transportfehler ist etwas anderes als ein
    /// klares Weg: der erste laesst den Eintrag stehen und wird
    /// wiederholt, der zweite vermerkt das Stueck als tot, damit die Reihe
    /// es auslaesst. Der HOERSTAND bleibt in beiden Faellen — er ist
    /// Nutzerbesitz; verschwinden darf die Kachel, nicht der Eintrag.
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
