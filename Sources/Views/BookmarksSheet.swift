// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Bookmarks of the current book: save the current position (with title), list
/// with jump on tap and delete on swipe. Server-side via the ABS bookmark API —
/// only available online (no offline queueing).
struct BookmarksSheet: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var bookmarks: [ABSBookmark] = []
    @State private var isLoading = true
    /// True when the list comes from the offline cache (+ pending ops)
    /// instead of a fresh server response.
    @State private var isOfflineView = false
    @State private var showTitleAlert = false
    @State private var newTitle = ""
    /// Captured when the alert opens — playback may continue meanwhile.
    @State private var pendingTime: Double = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        pendingTime = viewModel.currentTime
                        newTitle = defaultTitle(for: pendingTime)
                        showTitleAlert = true
                    } label: {
                        Label {
                            Text("Bookmark Current Position (\(formatted(viewModel.currentTime)))")
                        } icon: {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                }

                Section {
                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if bookmarks.isEmpty {
                        Text("No bookmarks yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                Task { await viewModel.seek(to: bookmark.time) }
                                dismiss()
                            } label: {
                                HStack {
                                    Text(formatted(bookmark.time))
                                        .font(.subheadline.bold())
                                        .monospacedDigit()
                                        .foregroundStyle(AppTheme.accent)
                                    Text(bookmark.title)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            Task { await delete(at: offsets) }
                        }
                    }
                } footer: {
                    if isOfflineView {
                        Text("Offline — changes will be synced later.")
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await reload() }
        .alert("New Bookmark", isPresented: $showTitleAlert) {
            TextField("Title", text: $newTitle)
            Button("Save") {
                Task { await create() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Chapter name (if any) is the most useful default title.
    private func defaultTitle(for time: Double) -> String {
        if let chapter = viewModel.chapters.last(where: { time >= $0.start }),
           !chapter.title.isEmpty {
            return chapter.title
        }
        return formatted(time)
    }

    private func formatted(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .hourMinuteSecond))
    }

    private func reload() async {
        guard let itemId = viewModel.item?.id else { return }
        isLoading = true
        // Try pending items first so the server list includes them.
        await BookmarkQueue.shared.flush(provider: viewModel.provider)
        do {
            let fresh = try await viewModel.provider.fetchBookmarks(itemId: itemId)
            BookmarkQueue.shared.cache(fresh, forItemId: itemId)
            isOfflineView = false
        } catch {
            isOfflineView = true
        }
        // Effective view = last known server list + still-pending ops.
        bookmarks = BookmarkQueue.shared.effectiveBookmarks(forItemId: itemId)
        isLoading = false
    }

    private func create() async {
        guard let itemId = viewModel.item?.id else { return }
        let raw = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = raw.isEmpty ? formatted(pendingTime) : raw
        do {
            try await viewModel.provider.createBookmark(itemId: itemId, time: pendingTime, title: title)
            await reload()
        } catch {
            // Offline/server error: queue it and show it optimistically.
            BookmarkQueue.shared.enqueue(.create(itemId: itemId, time: pendingTime, title: title))
            bookmarks = BookmarkQueue.shared.effectiveBookmarks(forItemId: itemId)
            isOfflineView = true
        }
    }

    private func delete(at offsets: IndexSet) async {
        guard let itemId = viewModel.item?.id else { return }
        let toDelete = offsets.map { bookmarks[$0] }
        for bookmark in toDelete {
            do {
                try await viewModel.provider.deleteBookmark(itemId: itemId, time: bookmark.time)
            } catch {
                BookmarkQueue.shared.enqueue(.delete(itemId: itemId, time: bookmark.time))
                isOfflineView = true
            }
        }
        if isOfflineView {
            // Effective view filters the queued deletes out of the cached list.
            bookmarks = BookmarkQueue.shared.effectiveBookmarks(forItemId: itemId)
        } else {
            await reload()
        }
    }
}
