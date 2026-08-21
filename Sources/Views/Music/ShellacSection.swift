// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// 🟡 P8: THE "Old Records" section — the three-level structure (a738dc4 +
/// 284095b) in ONE place, rendered by the music tab AND by "Discover ·
/// Music".
///
/// Measured root of the device finding: the collection page never had a
/// shelf LOADER at all. It rendered the capsules as navigation tiles and
/// nothing else — so the capsules were operable and led into emptiness,
/// with no row, no loading and no failure state (G8). Copying the tab's
/// block would have been the second version that drifts; this is the shared
/// one (Regel 2), and with it the collection page inherits the shelf line,
/// the loading state and the visible failure automatically.
///
/// Three levels, three targets: the row HEAD means the area (genre
/// overview), the capsules switch in place, the shelf LINE below them names
/// what the title row shows and leads counted into that shelf's full page.
struct ShellacSection: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.pushMusicRoute) private var pushRoute

    @State private var selectedShelfKey = ArchiveMusicCatalog.shellacShelves[0].key
    @State private var titles: [LibraryItem] = []
    @State private var isLoading = false
    @State private var failed = false

    private var selectedShelf: ArchiveMusicArea {
        ArchiveMusicCatalog.shelfOrFirst(key: selectedShelfKey)
    }

    var body: some View {
        SwitchableTileRow(
            state: isLoading && titles.isEmpty ? .loading
                : (titles.isEmpty ? (failed ? .failed : .empty) : .ready),
            emptyText: "Nothing in this shelf right now.",
            failedText: "This shelf could not be loaded. Check your connection."
        ) {
            RowHeading.entry("Old Records", destination: MusicRoute.shellacArea)
        } selector: {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(ArchiveMusicCatalog.shellacShelves) { shelf in
                        CategoryTile(title: shelf.title,
                                     systemImage: MusicGenreGlyphs.symbol(for: shelf.subject),
                                     count: nil,
                                     accessibilityId: "shellac-tile-\(shelf.key)",
                                     isSelected: shelf.key == selectedShelfKey) {
                            selectedShelfKey = shelf.key
                        }
                        .frame(width: 200)
                    }
                }
                .padding(.horizontal)
            }
            RowHeading(title: "", verbatimTitle: selectedShelf.title,
                       font: .headline,
                       total: selectedShelf.measuredTotal,
                       shown: titles.count,
                       showsTotal: true,
                       destination: MusicRoute.archiveMusic(selectedShelf))
                .catalogShuffle(area: selectedShelf, coordinator: playerCoordinator)
        } content: {
            tileRow
        }
        // The loading duty sits at the SURFACE that shows the data, never at
        // the path that happened to visit it — that was the defect.
        .task(id: selectedShelfKey) { await load() }
    }

    private var tileRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(RowPreview.cut(titles)) { item in
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: "music.note",
                        onTap: {
                            Task {
                                await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                                      pushMusicRoute: { pushRoute($0) })
                            }
                        })
                    .cardRowSlot(spacing: 14)
                    .contextMenu {
                        Button {
                            Task { await playerCoordinator.open(item: item) }
                        } label: { Label("Play", systemImage: "play.fill") }
                        CatalogQueueButtons(itemId: item.id)
                    }
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }

    private func load() async {
        isLoading = true
        failed = false
        defer { isLoading = false }
        let area = selectedShelf
        // Same daily rotation as the other popularity rows: the all-time
        // ranking would otherwise never change.
        let page = CatalogRotation.page(total: area.measuredTotal, rowSize: 12, on: Date())
        do {
            let docs = try await ArchiveOrgClient.popularMusic(area: area, rows: 12, page: page)
            // 🟡 P10-Nachfassung: a shown preview goes through the ONE probed
            // entry point — this row was a sibling surface that kept showing
            // withdrawn items.
            titles = await FreeCatalogLoader.picks(docs, cap: RowPreview.limit,
                                                 provider: FreeCatalogProvider.shared)
            failed = titles.isEmpty
        } catch {
            guard !error.isCancellation else { return }
            failed = true
            titles = []
            Logger.library.error("SHELLAC row \(area.key, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
        }
    }
}
