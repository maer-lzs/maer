// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import OSLog

/// 0714d26: the free-catalog Discover rows on Home — "New free audiobooks"
/// (LibriVox, keyless) · "Popular free audiobooks" (archive.org downloads
/// sort, keyless) · "Free music" (Jamendo, only with a client key). Tiles
/// play DIRECTLY (tap-to-play like radio); the context menu opens the
/// license/details sheet (public-domain badge resp. the Jamendo ToS
/// attribution with artist + backlink). Each row has its own opt-out on the
/// network-services page; rows are net-gated and hide silently when empty.
struct FreeCatalogRows: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// 34c36e1: the rows are DUMB now — a lazily-mounted, initially EMPTY
    /// view below the fold never ran its .task reliably (the third suspect);
    /// loading lives in HomeView's compute() pass (always runs, calm-gated)
    /// via `FreeCatalogLoader`.
    let newBooks: [LibraryItem]
    let popularBooks: [LibraryItem]
    let freeMusic: [LibraryItem]
    @State private var detailItem: LibraryItem?

    var body: some View {
        Group {
            if !newBooks.isEmpty {
                row(title: "New Free Audiobooks", items: newBooks)
            }
            if !popularBooks.isEmpty {
                row(title: "Popular Free Audiobooks", items: popularBooks)
            }
            if !freeMusic.isEmpty {
                row(title: "Free Music", items: freeMusic)
            }
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    private func row(title: LocalizedStringKey, items: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        MediaTile(
                            title: item.title,
                            subtitle: item.author,
                            coverURL: AppSession.shared.coverURL(forItemId: item.id),
                            placeholderSystemImage: item.id.hasPrefix(FreeCatalog.jamendoPrefix)
                                ? "music.note" : "book.closed",
                            onTap: { Task { await playerCoordinator.open(item: item) } }
                        )
                        .containerRelativeFrame(.horizontal,
                                                count: CardMetrics.recommendationColumns(regularWidth: false),
                                                spacing: 14)
                        .contextMenu {
                            Button {
                                detailItem = item
                            } label: { Label("Details", systemImage: "info.circle") }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
        }
    }
}

/// 34c36e1: the ONE loader — called from HomeView.compute() (always runs,
/// no lazy-mount dependency). WireCorpus discipline at the call sites: a
/// throwing client is CAUGHT and LOGGED with the actual error (never a
/// silent try?-collapse to empty); the per-row log line names loaded/
/// filtered counts and the reason when a row stays empty.
@MainActor
enum FreeCatalogLoader {
    struct Rows {
        var newBooks: [LibraryItem] = []
        var popularBooks: [LibraryItem] = []
        var freeMusic: [LibraryItem] = []
    }

    static func load() async -> Rows {
        var rows = Rows()
        #if DEBUG
        if UITestSeed.isActive { return rows }   // no external calls in the harness
        #endif
        let provider = FreeCatalogProvider.shared
        let librivoxOn = UserDefaults.standard.object(forKey: AppStorageKeys.librivoxRowsEnabled) as? Bool ?? true
        let archiveOn = UserDefaults.standard.object(forKey: AppStorageKeys.archivePopularEnabled) as? Bool ?? true
        let jamendoOn = UserDefaults.standard.object(forKey: AppStorageKeys.jamendoRowEnabled) as? Bool ?? true

        if librivoxOn {
            do {
                let books = try await LibriVoxClient.newBooks(sinceDays: 120, limit: 40)
                let codes = SuggestionLanguages.current()
                let filtered = FreeCatalog.filterByLanguages(books, codes: codes)
                Logger.library.notice("FREECAT librivox loaded=\(books.count) filtered=\(filtered.count) codes=\(codes.joined(separator: ","), privacy: .public)")
                rows.newBooks = filtered.prefix(12).map { provider.remember(book: $0) }
            } catch {
                Logger.library.error("FREECAT librivox FAILED: \(String(describing: error), privacy: .public)")
            }
        }
        if archiveOn {
            do {
                let docs = try await ArchiveOrgClient.popularLibriVox(rows: 12)
                Logger.library.notice("FREECAT archive-popular loaded=\(docs.count)")
                rows.popularBooks = docs.compactMap { provider.remember(popular: $0) }
            } catch {
                Logger.library.error("FREECAT archive-popular FAILED: \(String(describing: error), privacy: .public)")
            }
        }
        if jamendoOn {
            if JamendoClient.clientId() == nil {
                Logger.library.notice("FREECAT jamendo EMPTY: no client key")
            } else {
                do {
                    let tracks = try await JamendoClient.popularTracks(limit: 12)
                    Logger.library.notice("FREECAT jamendo loaded=\(tracks.count)")
                    rows.freeMusic = tracks.compactMap { provider.remember(track: $0) }
                } catch {
                    Logger.library.error("FREECAT jamendo FAILED: \(String(describing: error), privacy: .public)")
                }
            }
        }
        return rows
    }
}

/// License/details sheet: public-domain badge for LibriVox/archive items;
/// Jamendo carries the ToS-mandated artist credit, "via Jamendo" and the
/// DIRECT backlink to the track page.
struct FreeCatalogDetailSheet: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss

    private var isJamendo: Bool { item.id.hasPrefix(FreeCatalog.jamendoPrefix) }
    private var jamendoTrack: JamendoTrack? {
        FreeCatalogProvider.shared.jamendoTrack(forId: item.id)
    }
    private var librivoxURL: URL? {
        FreeCatalogProvider.shared.librivoxBook(forId: item.id)?.url_librivox.flatMap { URL(string: $0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                CachedAsyncImage(url: AppSession.shared.coverURL(forItemId: item.id)) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                        .overlay(Image(systemName: isJamendo ? "music.note" : "book.closed")
                            .font(.largeTitle).foregroundStyle(.secondary))
                }
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 4) {
                    Text(item.title).font(.headline).multilineTextAlignment(.center)
                    if let author = item.author {
                        Text(author).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if isJamendo {
                    // ToS: artist credit + provider credit + direct backlink.
                    VStack(spacing: 6) {
                        Label("Creative Commons — via Jamendo", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.secondary)
                        if let share = jamendoTrack?.shareurl.flatMap({ URL(string: $0) }) {
                            Link(destination: share) {
                                Label("View on Jamendo", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        Label("Public Domain — free to listen and share", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.secondary)
                        if let url = librivoxURL {
                            Link(destination: url) {
                                Label("View on LibriVox", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                    }
                }

                Button {
                    dismiss()
                    Task { await playerCoordinator.open(item: item) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                Spacer(minLength: 0)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
