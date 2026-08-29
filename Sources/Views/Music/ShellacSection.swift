// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// THE "Old Records" row, rendered by the music tab AND by "Discover ·
/// Music". One view for both, so the two cannot drift apart.
///
/// It is an ordinary catalogue tile row now, built like the netlabels and
/// Jamendo rows: a heading with a chevron, tiles below it. It used to carry
/// three levels in one row (selection capsules that switched the shelf in
/// place, and a second heading naming the selected shelf). The nine shelves
/// live on the surface behind the chevron, which shows them below its own
/// popular row.
///
/// The content is the PARENT query of the shelves, so the row and the
/// shelves draw from one basis instead of two.
struct ShellacSection: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.pushMusicRoute) private var pushRoute

    @State private var titles: [LibraryItem] = []
    @State private var isLoading = false
    @State private var failed = false

    private var area: ArchiveMusicArea { ArchiveMusicCatalog.shellacAll }

    /// The row reaches into a DIFFERENT place of the same stock than the
    /// popular row on the surface behind the chevron. Both rotate daily; with
    /// the same seed they would begin with the same tiles, and the chevron
    /// would lead to what the user is already looking at.
    static let rowSalt = CatalogRotation.salt(forShelf: "shellac-all-row")

    /// The store slot of this row. The area page files its own row under the
    /// area key too, and two rows of the same area on different pages must
    /// not overwrite each other's day.
    static let rowSlot = "popular-row"

    var body: some View {
        SwitchableTileRow(
            state: isLoading && titles.isEmpty ? .loading
                : (titles.isEmpty ? (failed ? .failed : .empty) : .ready),
            emptyText: "Nothing in this shelf right now.",
            failedText: "This shelf could not be loaded. Check your connection."
        ) {
            RowHeading.entry("Old Records", destination: MusicRoute.shellacArea)
                .catalogShuffle(area: area, coordinator: playerCoordinator)
        } content: {
            tileRow
        }
        .task { await load() }
    }

    private var tileRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(RowPreview.cut(titles)) { item in
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: "music.note",
                        hidesUnstatedRights: area.statesUniformRights,
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
        guard titles.isEmpty else { return }
        isLoading = true
        failed = false
        defer { isLoading = false }
        let area = area
        // Same daily rotation as the other popularity rows: the all-time
        // ranking would otherwise never change.
        let page = CatalogRotation.page(total: area.measuredTotal, rowSize: 12,
                                        on: Date(), salt: Self.rowSalt)
        do {
            let docs = try await CatalogShelfSource.areaPopular(
                area: area, rows: 12, page: page, slot: Self.rowSlot,
                storedDay: CatalogShelfSource.storedDay(surface: area.key))
            // A shown preview goes through the ONE probed entry point. This
            // row was a sibling surface that kept showing withdrawn items.
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
