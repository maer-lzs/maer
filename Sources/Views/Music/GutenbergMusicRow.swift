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
            let items = CatalogShelfEntries.gutenbergMusic(GutenbergMusic.lane(stock, rows: RowPreview.limit, on: Date()))
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    RowHeading.plain(verbatim: "Project Gutenberg")
                        .accessibilityIdentifier("classical-gutenberg-section")
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
