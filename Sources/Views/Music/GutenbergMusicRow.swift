// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The music works of Project Gutenberg on the classical page: one row from
/// the kept stock (`GutenbergMusic.lane`), the composer under each title.
/// Without a kept stock, or with the source off, the row is not there.
struct GutenbergMusicRow: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// The page's own service of the kept stocks.
    @ObservedObject var stockService: CatalogStockService

    var body: some View {
        if AppStorageKeys.gutenbergSourceActive,
           let stock = stockService.stock(CatalogSource.gutenberg.rawValue) {
            let items = CatalogShelfEntries.gutenbergMusic(GutenbergMusic.lane(stock, rows: RowPreview.limit, on: Date(), classical: true))
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    RowHeading.entry(verbatim: "Project Gutenberg", destination: MusicRoute.gutenbergMusic(classical: true))
                        .accessibilityIdentifier("classical-gutenberg-section")
                    Text(GutenbergMusic.rightsNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(items) { item in
                                FreeCatalogBookTile(item: item, placeholderSystemImage: "music.note") {
                                    Task {
                                        await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                                              pushMusicRoute: { pushRoute($0) })
                                    }
                                }
                                .cardRowSlot(spacing: 14)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .rowReachesUnderSideColumn()
                }
            }
        }
    }
}

/// Every music work of Project Gutenberg, behind the row of the classical
/// page: the sentence of the row, then all works in popularity order.
struct GutenbergMusicPage: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject var stockService: CatalogStockService
    /// Art music (the classical page) or the rest (the music page).
    let classical: Bool
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        let items = stockService.stock(CatalogSource.gutenberg.rawValue)
            .map { CatalogShelfEntries.gutenbergMusic(GutenbergMusic.all($0, classical: classical)) } ?? []
        Group {
            if items.isEmpty {
                EmptyStateView(title: Text(verbatim: "Project Gutenberg"), systemImage: "music.note")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text(GutenbergMusic.rightsNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .foldLeadingHalf()
                        CoverGrid(columns: columns) {
                            ForEach(items) { item in
                                FreeCatalogBookTile(item: item, placeholderSystemImage: "music.note") {
                                    Task {
                                        await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                                              pushMusicRoute: { pushRoute($0) })
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.top, TabContentLayout.topInset)
                    .bottomBarClearance()
                }
            }
        }
        .navigationTitle(Text(verbatim: "Project Gutenberg"))
    }
}
