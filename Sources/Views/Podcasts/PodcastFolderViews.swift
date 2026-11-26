// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The row "Folders" in the Podcasts tab: each folder as a tile with the
/// mosaic of its shows' covers, the new episodes of all its shows and a
/// start button; "+" makes a new folder. A folder is a Mär playlist of shows
/// (`PodcastFolder`).
struct PodcastFolderRow: View {
    /// The side of a tile on a wide screen, where the rule would grow it.
    static let widestSide: CGFloat = 240

    /// The side of a folder's tile from the width of the row: two tiles in
    /// full and four tenths of the third at the edge, so the row says it
    /// goes on. The width alone decides, so the row stands as high with
    /// two folders as with eight; on a wide screen `widestSide` holds it.
    nonisolated static func side(forWidth width: CGFloat) -> CGFloat {
        let edge: CGFloat = 16, spacing: CGFloat = 14
        return min(widestSide, max(0, (width - edge - 2 * spacing) / 2.4))
    }

    /// The new episodes per feed key, as the subscription grid counts them.
    let newCounts: [String: Int]
    /// The newest episode (ms) and the unplayed episodes per feed key, for
    /// the sort of the folders.
    var newest: [String: Double] = [:]
    var unplayed: [String: Int] = [:]
    /// The subscriptions, for the suggested folders.
    var subscriptions: [PodcastShow] = []
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// The hint to suggest folders, put away on this device.
    @AppStorage(AppStorageKeys.smartFoldersHintDismissed) private var hintDismissed = false
    @State private var suggesting: [SmartFolderSuggestion.Suggestion]?
    /// The one sort of the folders, here and on the page of all folders.
    @AppStorage(AppStorageKeys.podcastFoldersSort) private var sortRaw = PodcastSortOption.zuletztAktualisiert.rawValue

    /// The folders in the chosen sort, by the shows they hold.
    static func ordered(_ folders: [MaerPlaylists.Playlist], by option: PodcastSortOption,
                        newest: [String: Double], unplayed: [String: Int]) -> [MaerPlaylists.Playlist] {
        PodcastFolderSort.sorted(folders, by: option, name: \.name,
                                 newest: { $0.itemIds.compactMap(PodcastFolder.feedKey(of:)).compactMap { newest[$0] }.max() ?? 0 },
                                 unplayed: { $0.itemIds.compactMap(PodcastFolder.feedKey(of:)).reduce(0) { $0 + (unplayed[$1] ?? 0) } })
    }
    @ObservedObject private var store = MaerPlaylists.shared
    @State private var creating = false
    /// The width of the row as laid out; a phone's until it is measured.
    @State private var rowWidth: CGFloat = 393

    var body: some View {
        let folders = Self.ordered(SharedRows.playlists(at: .podcasts).filter { PodcastFolder.isFolder($0.itemIds) },
                                   by: PodcastSortOption(rawValue: sortRaw) ?? .zuletztAktualisiert,
                                   newest: newest, unplayed: unplayed)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if folders.isEmpty {
                    RowHeading.plain("Folders")
                } else {
                    RowHeading.entry("Folders", destination: PodcastRoute.folders)
                }
                Spacer(minLength: 0)
                Button { creating = true } label: {
                    Image(systemName: "plus.circle").font(.title3)
                }
                .accessibilityLabel(Text("New Folder"))
                .accessibilityIdentifier("podcast-folder-new")
                .padding(.trailing)
            }
            let folderLists = store.playlists.filter { PodcastFolder.isFolder($0.itemIds) }
            let suggestions = SmartFolderSuggestion.suggest(SmartFolders.shows(subscriptions, folders: folderLists),
                                                            folderNames: Set(folderLists.map(\.name)))
            if SmartFolderSuggestion.showsHint(subscriptions: subscriptions.count, suggestions: suggestions.count, dismissed: hintDismissed) {
                SmartFolderHint(open: { suggesting = suggestions }, putAway: { hintDismissed = true })
                    .padding(.horizontal)
            }
            if folders.isEmpty {
                Text("Put shows together in a folder and start them in one tap.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(folders) { folder in
                            NavigationLink(value: PodcastRoute.folder(id: folder.id)) {
                                PodcastFolderTile(folder: folder,
                                                  newCount: PodcastFolder.newCount(folder.itemIds) { newCounts[$0] ?? 0 },
                                                  side: PodcastFolderRow.side(forWidth: rowWidth)) {
                                    Task { await RoutinePlayback.start(folder, in: store, on: playerCoordinator) }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("podcast-folder-\(folder.id)")
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .sheet(isPresented: $creating) {
            AddShowToFolderSheet(show: nil).followsAppearanceChoice()
        }
        .sheet(item: Binding(get: { suggesting.map(SmartFolderPreview.init) }, set: { suggesting = $0?.suggestions })) { preview in
            SmartFolderSheet(suggestions: preview.suggestions, titles: Dictionary(
                subscriptions.map { (PodcastIdentity.feedKey($0.feedURL), $0.title) }, uniquingKeysWith: { first, _ in first }),
                store: store)
                .followsAppearanceChoice()
        }
    }
}

/// One folder's tile: the mosaic, the new episodes at the top right, the
/// start at the bottom right, the name and the number of shows.
struct PodcastFolderTile: View {
    let folder: MaerPlaylists.Playlist
    let newCount: Int
    /// The row's rule gives the side; the page's grid gives its column.
    var side: CGFloat?
    let start: () -> Void
    @Environment(\.itemRouter) private var router
    /// The side measured where the grid decides it, for the marks.
    @State private var measured: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlaylistArtwork(playlistID: folder.id,
                            coverURLs: PlaylistCardSource.deviceCovers(folder, router: router),
                            cornerRadius: 12)
                .frame(width: side, height: side)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: side == nil ? .infinity : nil)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured = $0 }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if newCount > 0, PodcastFolderSettings.read(folderId: folder.id).showsCount {
                        StandardCoverMarks(count: newCount, coverSide: side ?? measured)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    CardCornerButton(systemImage: "play.fill", accessibilityLabel: Text("Play"),
                                     accessibilityId: "podcast-folder-play-\(folder.id)", action: start)
                        .padding(6)
                }
            Text(folder.name)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text("\(folder.itemIds.count) shows")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: side, alignment: .leading)
    }
}

/// Every folder of shows, behind the heading of the row: the same tiles in
/// a grid, in the one sort of the folders chosen here and kept by the row.
struct PodcastFoldersPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var store = MaerPlaylists.shared
    /// The new episodes per feed key, counted as the folder page counts.
    @State private var counts: [String: Int] = [:]
    @State private var newest: [String: Double] = [:]
    @State private var unplayed: [String: Int] = [:]
    /// The one sort of the folders, as in their row; it travels like the
    /// books' sort.
    @AppStorage(AppStorageKeys.podcastFoldersSort) private var sortRaw = PodcastSortOption.zuletztAktualisiert.rawValue

    private var sort: PodcastSortOption { PodcastSortOption(rawValue: sortRaw) ?? .zuletztAktualisiert }

    var body: some View {
        let all = SharedRows.playlists(at: .podcasts).filter { PodcastFolder.isFolder($0.itemIds) }
        let folders = PodcastFolderRow.ordered(all, by: sort, newest: newest, unplayed: unplayed)
        ScrollView {
            HStack {
                Spacer(minLength: 12)
                SectionSortControl(activeLabel: SortIndicator.summary([
                    SortIndicator.part(sort.label, ifNot: sort == .zuletztAktualisiert),
                ])) {
                    Picker("Sort", selection: $sortRaw) {
                        ForEach(PodcastSortOption.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                }
                .padding(.horizontal)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: PodcastFolderRow.widestSide), spacing: 14)],
                      alignment: .leading, spacing: 18) {
                ForEach(folders) { folder in
                    NavigationLink(value: PodcastRoute.folder(id: folder.id)) {
                        PodcastFolderTile(folder: folder,
                                          newCount: PodcastFolder.newCount(folder.itemIds) { counts[$0] ?? 0 }) {
                            Task { await RoutinePlayback.start(folder, in: store, on: playerCoordinator) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("podcast-folders-\(folder.id)")
                }
            }
            .padding(.horizontal)
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .navigationTitle("Folders")
        .navigationBarTitleDisplayMode(.inline)
        // A chosen sort is a user statement that travels.
        .onChange(of: sortRaw) { _, new in
            UserChoiceCloudSync.shared.noteScalar(key: AppStorageKeys.podcastFoldersSort, value: new)
        }
        .taskOnPodcastChange(all.map { $0.itemIds.joined(separator: ",") }.joined(separator: ";")) {
            let shows = all.flatMap(\.itemIds).compactMap(PodcastFolder.feedKey(of:)).compactMap(RoutinePlayback.show(feedKey:))
            let sections = await PodcastSections.computeDetached(shows: shows, snapshot: PodcastSections.snapshot(shows: shows))
            counts = Dictionary(sections.recentShows.map { (PodcastIdentity.feedKey($0.show.feedURL), $0.newCount) },
                                uniquingKeysWith: { first, _ in first })
            newest = Dictionary(sections.recentShows.map { (PodcastIdentity.feedKey($0.show.feedURL), $0.lastUpdated) },
                                uniquingKeysWith: { first, _ in first })
            unplayed = Dictionary(sections.recentShows.map { (PodcastIdentity.feedKey($0.show.feedURL), $0.unplayedCount) },
                                  uniquingKeysWith: { first, _ in first })
        }
    }
}

/// A folder's page: the mosaic with its name and counts, Play and Shuffle
/// over the newest unheard episode of each show, the sentence that says so,
/// and the grid of its shows. A show leaves the folder from its menu; the
/// page menu edits the folder in the sheet it was made in (name and shows)
/// and deletes it, which gives its shows back to the loose grid.
struct PodcastFolderPage: View {
    let folderId: String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var store = MaerPlaylists.shared
    /// The host of the show tiles asks their locks while observing the
    /// store, as the subscriptions page does.
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @Environment(\.itemRouter) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var infos: [RecentShowInfo] = []
    @State private var editing: MaerPlaylists.Playlist?
    /// The folder's settings as the page shows them: read when it appears,
    /// when the edit sheet closes and when choices arrive from another
    /// device, so the line and the order follow a change.
    @State private var settings = PodcastFolderSettings()
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let folder = store.playlist(id: folderId), PodcastFolder.isFolder(folder.itemIds) {
                page(folder)
            } else {
                Color.clear
            }
        }
        // The folder went (its last show left, or another device deleted
        // it) while the page was open: the page goes with it.
        .onChange(of: store.playlist(id: folderId) == nil) { _, gone in
            if gone { dismiss() }
        }
        .navigationTitle(store.playlist(id: folderId)?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .pageActions("podcast-folder-actions", shown: store.playlist(id: folderId) != nil) {
            Button {
                editing = store.playlist(id: folderId)
            } label: { Label("Edit Folder", systemImage: "pencil") }
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
        .sheet(item: $editing, onDismiss: { settings = PodcastFolderSettings.read(folderId: folderId) }) { folder in
            AddShowToFolderSheet(show: nil, editing: folder).followsAppearanceChoice()
        }
        .confirmationDialog("Delete Folder", isPresented: $confirmingDelete) {
            Button("Delete Folder", role: .destructive) {
                store.delete(playlistId: folderId)
                dismiss()
            }
        } message: {
            Text("The shows stay subscribed and return to Subscriptions.")
        }
        .onAppear { settings = PodcastFolderSettings.read(folderId: folderId) }
        .onReceive(NotificationCenter.default.publisher(for: .userChoicesAdopted)) { _ in settings = PodcastFolderSettings.read(folderId: folderId) }
        .taskOnPodcastChange((store.playlist(id: folderId)?.itemIds.joined(separator: ",") ?? "") + "|" + settings.order.rawValue) {
            let entries = store.playlist(id: folderId)?.itemIds ?? []
            let shows = entries.compactMap(PodcastFolder.feedKey(of:)).compactMap(RoutinePlayback.show(feedKey:))
            let snapshot = PodcastSections.snapshot(shows: shows)
            let sections = await PodcastSections.computeDetached(shows: shows, snapshot: snapshot)
            infos = PodcastFolderOrder.sorted(RecentShowInfo.inFolder(sections.recentShows, entries: entries),
                                              by: settings.order,
                                              key: { PodcastIdentity.feedKey($0.show.feedURL) },
                                              title: { $0.show.title }, newest: { $0.lastUpdated })
        }
    }

    private func page(_ folder: MaerPlaylists.Playlist) -> some View {
        let newCount = infos.reduce(0) { $0 + $1.newCount }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(title: folder.name) { side in
                    PlaylistArtwork(playlistID: folder.id,
                                    coverURLs: PlaylistCardSource.deviceCovers(folder, router: router, limit: .max))
                        .frame(maxWidth: side ?? 240)
                        .coverCard()
                } lines: {
                    (Text("\(folder.itemIds.count) shows") + Text(verbatim: " · ") + Text("\(newCount) new episodes"))
                        .font(.caption).foregroundStyle(.secondary)
                } actions: {
                    HStack(spacing: 12) {
                        DetailMainButton(title: String(localized: "Play"), systemImage: "play.fill") {
                            Task { await RoutinePlayback.start(folder, in: store, on: playerCoordinator) }
                        }
                        Button {
                            Task { await RoutinePlayback.start(folder, in: store, on: playerCoordinator, shuffled: true) }
                        } label: {
                            Image(systemName: "shuffle")
                        }
                        .font(.title3)
                        .accessibilityLabel(Text("Shuffle"))
                        .accessibilityIdentifier("podcast-folder-shuffle")
                    }
                }
                .padding(.horizontal)
                if let line = PodcastFolderPlay.line(for: settings.start) {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 14)],
                          alignment: .leading, spacing: 18) {
                    ForEach(infos) { info in
                        NavigationLink(value: PodcastRoute.show(feedURL: info.show.feedURL)) {
                            RecentShowTile(info: info, lock: subs.lock(feedURL: info.show.feedURL))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                store.unfile(show: PodcastIdentity.feedKey(info.show.feedURL), from: folder.id)
                            } label: {
                                Label("Remove from Folder", systemImage: "folder.badge.minus")
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
        }
    }
}
