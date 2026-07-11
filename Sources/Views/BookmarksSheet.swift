import SwiftUI

/// Lesezeichen des aktuellen Buchs: aktuelle Position sichern (mit Titel),
/// Liste mit Springen per Tap und Löschen per Swipe. Serverseitig über die
/// ABS-Bookmark-API — nur online verfügbar (kein Offline-Queueing).
struct BookmarksSheet: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var bookmarks: [ABSBookmark] = []
    @State private var isLoading = true
    @State private var errorText: String?
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
                    } else if let errorText {
                        Text(errorText).foregroundStyle(.secondary)
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
        do {
            bookmarks = try await viewModel.apiClient.fetchBookmarks(itemId: itemId)
            errorText = nil
        } catch {
            errorText = String(localized: "Bookmarks could not be loaded.")
        }
        isLoading = false
    }

    private func create() async {
        guard let itemId = viewModel.item?.id else { return }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await viewModel.apiClient.createBookmark(
                itemId: itemId,
                time: pendingTime,
                title: title.isEmpty ? formatted(pendingTime) : title
            )
            await reload()
        } catch {
            errorText = String(localized: "Bookmark could not be saved.")
        }
    }

    private func delete(at offsets: IndexSet) async {
        guard let itemId = viewModel.item?.id else { return }
        for index in offsets {
            let bookmark = bookmarks[index]
            try? await viewModel.apiClient.deleteBookmark(itemId: itemId, time: bookmark.time)
        }
        await reload()
    }
}
