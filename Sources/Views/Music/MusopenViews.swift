// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The symbol of the Musopen page while it has no recording to show.
enum MusopenTile {
    static let placeholderSystemImage = "music.note"
}

/// The drawn cover of a recording (`MusopenCoverArt`): the composer's
/// colour, the composer and the work in white. The text is sized by the
/// picture, not by the reading size, like the print on a sleeve, and shrinks
/// to fit instead of breaking off; the tile and the player name the
/// recording in their own text, so the cover is hidden from VoiceOver.
struct MusopenCover: View {
    let title: String
    let composer: String?

    var body: some View {
        let lines = MusopenCoverArt.lines(title: title, composer: composer)
        let rgb = MusopenCoverArt.colour(composer: lines.composer)
        GeometryReader { geo in
            let side = geo.size.width
            VStack(alignment: .leading, spacing: side * 0.04) {
                if let name = lines.composer {
                    Text(verbatim: name)
                        .font(.system(size: side * 0.10, weight: .semibold))
                        .opacity(0.85)
                }
                Text(verbatim: lines.work)
                    .font(.system(size: side * 0.15, weight: .bold))
            }
            .foregroundStyle(.white)
            .minimumScaleFactor(0.35)
            .padding(side * 0.09)
            .frame(width: side, height: side, alignment: .topLeading)
            .background(Color(red: rgb[0], green: rgb[1], blue: rgb[2]))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
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
    @State private var items: [LibraryItem] = []
    /// Where the next answer starts; nil once every category is read.
    @State private var cursor: MusopenCatalog.Cursor? = MusopenCatalog.Cursor()
    @State private var isLoading = false
    @State private var loadFailed = false

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        Group {
            if items.isEmpty && (isLoading || (cursor != nil && !loadFailed)) {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if items.isEmpty {
                if loadFailed {
                    LoadFailedView(form: .page(title: Text(verbatim: "Musopen"),
                                               systemImage: MusopenTile.placeholderSystemImage),
                                   sentence: "Could not load the catalog. Check your connection and try again.") {
                        Task { await loadMore() }
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
                            ForEach(items) { item in
                                MusopenItemTile(item: item, playerCoordinator: playerCoordinator)
                                    .onAppear {
                                        if item.id == items.last?.id { Task { await loadMore() } }
                                    }
                            }
                        }
                        .padding(.horizontal)
                        if isLoading {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                    .padding(.top, TabContentLayout.topInset)
                    .bottomBarClearance()
                }
            }
        }
        .navigationTitle(Text(verbatim: "Musopen"))
        .task {
            if items.isEmpty { await loadMore() }
        }
    }

    /// The next answer from where the reader stands. An answer whose files
    /// all stay out is read past, a few at most, so a scroll always brings
    /// recordings when there are any further on.
    private func loadMore() async {
        guard !isLoading, var from = cursor else { return }
        isLoading = true
        defer { isLoading = false }
        for _ in 0..<3 {
            let answer = await MusopenLoader.next(from: from)
            switch answer.outcome {
            case .loaded(let found, _):
                loadFailed = false
                let known = Set(items.map(\.id))
                items += found.filter { !known.contains($0.id) }
                cursor = answer.next
                guard found.isEmpty, let next = answer.next else { return }
                from = next
            case .failed:
                loadFailed = true
                return
            case .cancelled:
                return
            }
        }
    }
}
