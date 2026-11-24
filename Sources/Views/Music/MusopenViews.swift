// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The symbol of the Musopen page while it has no recording to show.
enum MusopenTile {
    static let placeholderSystemImage = "music.note"
}

/// The drawn cover of a recording (`MusopenCoverArt`): a soft diagonal
/// between the two colours of the composer's family name, its initial large
/// and translucent, cut by the lower right corner, and over it the composer
/// and the work in full white. The text is sized by the picture, not by the
/// reading size, like the print on a sleeve, and shrinks to fit instead of
/// breaking off; the tile and the player name the recording in their own
/// text, so the cover is hidden from VoiceOver.
struct MusopenCover: View {
    let title: String
    let composer: String?

    private func colour(_ rgb: [Double]) -> Color { Color(red: rgb[0], green: rgb[1], blue: rgb[2]) }

    var body: some View {
        let lines = MusopenCoverArt.lines(title: title, composer: composer)
        let art = MusopenCoverArt.art(composer: lines.composer)
        let initial = MusopenCoverArt.initial(composer: lines.composer, title: lines.work)
        GeometryReader { geo in
            let side = geo.size.width
            ZStack(alignment: .topLeading) {
                // The diagonal round Goethe's circle, its stops in OKLCH, so
                // two opposites do not meet in grey.
                LinearGradient(colors: art.stops.map(colour), startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(verbatim: initial)
                    .font(.system(size: side * 0.95, weight: .black))
                    .foregroundStyle(Color(white: MusopenCoverArt.letterShade).opacity(MusopenCoverArt.letterOpacity))
                    .fixedSize()
                    .frame(width: side, height: side, alignment: .bottomTrailing)
                    .offset(x: side * 0.12, y: side * 0.22)
                VStack(alignment: .leading, spacing: side * 0.04) {
                    if let name = lines.composer {
                        Text(verbatim: name)
                            .font(.system(size: side * 0.10, weight: .semibold))
                    }
                    Text(verbatim: lines.work)
                        .font(.system(size: side * 0.15, weight: .bold))
                }
                .foregroundStyle(art.darkText ? colour(MusopenCoverArt.darkText) : .white)
                .minimumScaleFactor(0.35)
                .padding(side * 0.09)
                .frame(width: side, height: side, alignment: .topLeading)
            }
            .frame(width: side, height: side)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The picture behind a drawn cover's address (`DrawnCover`): the drawing
/// rendered once into PNG bytes, which the door of the covers keeps like
/// any fetched cover.
@MainActor
enum DrawnCoverRenderer {
    /// The side of the rendered picture in pixels, the size of a large cover.
    static let side: CGFloat = 600

    static func png(for url: URL) -> Data? {
        guard let parts = DrawnCover.parts(of: url) else { return nil }
        let renderer = ImageRenderer(content: MusopenCover(title: parts.title, composer: parts.composer)
            .frame(width: side, height: side))
        renderer.scale = 1
        return renderer.uiImage?.pngData()
    }
}

/// The Musopen row: its heading leads to the page of all recordings, the
/// tiles come from the store's row of the day. It stands on the Music tab
/// among the open catalogs and on the Classical page; with its switch off
/// it is not there, and a row that stayed empty says why. On a page whose
/// own rights sentence speaks of another source, the row carries its own.
struct MusopenRow: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    var showsRights = false
    @ObservedObject private var store = FreeCatalogStore.shared

    var body: some View {
        if AppStorageKeys.musopenActive {
            let rows = store.rows
            VStack(alignment: .leading, spacing: 8) {
                RowHeading.entry(verbatim: "Musopen", destination: MusicRoute.musopen)
                if showsRights {
                    Text(MusopenCatalog.rightsNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                if !rows.musopen.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(RowPreview.cut(rows.musopen)) { item in
                                MusopenItemTile(item: item, playerCoordinator: playerCoordinator)
                                    .cardRowSlot(spacing: 14)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .rowReachesUnderSideColumn()
                } else if let problem = rows.problems[.musopen] {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
        }
    }
}

/// One recording as the catalogs' tile: a tap plays it; its menu carries
/// the download entry of music, offered while online.
struct MusopenItemTile: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator

    var body: some View {
        FreeCatalogBookTile(
            item: item,
            placeholderSystemImage: MusopenTile.placeholderSystemImage,
            onTap: {
                Task {
                    await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                          pushMusicRoute: { pushRoute($0) })
                }
            })
        .contextMenu {
            CatalogDetailsButton(itemId: item.id)
            CatalogQueueButtons(itemId: item.id)
            MusicDownloadMenuItems(itemId: item.id)
        }
    }
}

/// Every recording of the catalog in a grid, read on while scrolling.
/// The rights stand once at the top; each recording names its own licence
/// on its page.
struct MusopenPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// What the page holds, where it reads on and whether it failed
    /// (`MusopenPageReading`).
    @State private var reading = MusopenPageReading()
    @State private var isLoading = false

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    private var items: [LibraryItem] { reading.items }

    var body: some View {
        Group {
            if items.isEmpty && (isLoading || (reading.cursor != nil && !reading.failed)) {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if items.isEmpty {
                if reading.failed {
                    LoadFailedView(form: .page(title: Text(verbatim: "Musopen"),
                                               systemImage: MusopenTile.placeholderSystemImage),
                                   sentence: "Could not load the catalog. Check your connection and try again.") {
                        Task { await readAll() }
                    }
                } else {
                    EmptyStateView(title: Text(verbatim: "Musopen"), systemImage: MusopenTile.placeholderSystemImage)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text(MusopenCatalog.rightsNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .foldLeadingHalf()
                        CoverGrid(columns: columns) {
                            ForEach(MusopenOrder.ordered(items, title: { $0.title }, composer: { $0.author })) { item in
                                MusopenItemTile(item: item, playerCoordinator: playerCoordinator)
                            }
                        }
                        .padding(.horizontal)
                        if isLoading {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        } else if reading.showsFailedLine {
                            // A failure in the middle: what was read stays,
                            // and the retry reads on from where it stood.
                            LoadFailedView(form: .line) { Task { await readAll() } }
                                .padding()
                        }
                    }
                    .padding(.top, TabContentLayout.topInset)
                    .bottomBarClearance()
                }
            }
        }
        .navigationTitle(Text(verbatim: "Musopen"))
        .task {
            // Also when the page appears again after being left in the
            // middle of its reading (`readsOnAppear`).
            if reading.readsOnAppear { await readAll() }
        }
    }

    /// Every answer in turn through the one reading, the page updated after
    /// each; also "Try Again", which reads on from where it stood. One run
    /// at a time.
    private func readAll() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        reading = await MusopenPageReading.readAll(reading, fetch: { await MusopenLoader.next(from: $0) }) { reading = $0 }
    }
}
