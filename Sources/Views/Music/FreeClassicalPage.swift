// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import OSLog

/// 50f4751: the SEPARATE "Free Classical" catalog area behind its own music
/// browse entry — external free catalog, clearly marked as such (header line
/// + public-domain badge in the detail sheet); NEVER mixed into the personal
/// library surfaces. Popularity-sorted grid (archive.org downloads), paged;
/// tiles play directly, context menu opens the license sheet.
struct FreeClassicalPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var page = 1
    @State private var reachedEnd = false
    @State private var detailItem: LibraryItem?

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        Group {
            if items.isEmpty && isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if items.isEmpty {
                if loadFailed {
                    ContentUnavailableView {
                        Label("Free Classical", systemImage: "music.quarternote.3")
                    } description: {
                        Text("Could not load the catalog. Check your connection and try again.")
                    } actions: {
                        Button("Retry") { Task { await loadMore(reset: true) } }
                    }
                } else {
                    ContentUnavailableView("Free Classical", systemImage: "music.quarternote.3")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        // Clear external-catalog marking (Katalog ≠ Bibliothek).
                        Text("Free public-domain recordings from the Internet Archive — separate from your own library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                        CoverGrid(columns: columns) {
                            ForEach(items) { item in
                                MediaTile(
                                    title: item.title,
                                    subtitle: item.author,
                                    coverURL: AppSession.shared.coverURL(forItemId: item.id),
                                    placeholderSystemImage: "music.quarternote.3",
                                    onTap: { Task { await playerCoordinator.open(item: item) } }
                                )
                                .contextMenu {
                                    Button {
                                        detailItem = item
                                    } label: { Label("Details", systemImage: "info.circle") }
                                }
                                .onAppear {
                                    if item.id == items.last?.id { Task { await loadMore() } }
                                }
                            }
                        }
                        .padding(.horizontal)
                        if isLoading && !items.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                    .padding(.top, TabContentLayout.topInset)
                    .bottomBarClearance()
                }
            }
        }
        .navigationTitle(Text("Free Classical"))
        .task { if items.isEmpty { await loadMore(reset: true) } }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    private func loadMore(reset: Bool = false) async {
        // 5034add: master off ⇒ no traffic even if the route is still open.
        guard UserDefaults.standard.object(forKey: AppStorageKeys.freeCatalogsMasterEnabled) as? Bool ?? true else { return }
        guard !isLoading, !reachedEnd || reset else { return }
        if reset { page = 1; reachedEnd = false; loadFailed = false }
        isLoading = true
        defer { isLoading = false }
        do {
            let docs = try await ArchiveOrgClient.popularClassical(rows: pageSize, page: page)
            Logger.library.notice("FREECAT classical page=\(page) loaded=\(docs.count)")
            let provider = FreeCatalogProvider.shared
            let new = docs.compactMap { provider.remember(popular: $0) }
            if new.isEmpty { reachedEnd = true; return }
            var seen = Set(items.map(\.id))
            items += new.filter { seen.insert($0.id).inserted }
            page += 1
            if docs.count < pageSize { reachedEnd = true }
        } catch {
            Logger.library.error("FREECAT classical FAILED: \(String(describing: error), privacy: .public)")
            loadFailed = items.isEmpty
        }
    }
}
