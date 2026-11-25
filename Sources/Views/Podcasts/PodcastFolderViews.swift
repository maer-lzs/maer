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
    static let widestSide: CGFloat = 240
    nonisolated static func side(forWidth width: CGFloat) -> CGFloat { 150 }

    /// The new episodes per feed key, as the subscription grid counts them.
    let newCounts: [String: Int]
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var store = MaerPlaylists.shared
    @State private var creating = false

    var body: some View {
        let folders = SharedRows.playlists(at: .podcasts).filter { PodcastFolder.isFolder($0.itemIds) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RowHeading.plain("Folders")
                Spacer(minLength: 0)
                Button { creating = true } label: {
                    Image(systemName: "plus.circle").font(.title3)
                }
                .accessibilityLabel(Text("New Folder"))
                .accessibilityIdentifier("podcast-folder-new")
                .padding(.trailing)
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
                                                  newCount: PodcastFolder.newCount(folder.itemIds) { newCounts[$0] ?? 0 }) {
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
        .sheet(isPresented: $creating) {
            AddShowToFolderSheet(show: nil).followsAppearanceChoice()
        }
    }
}

/// One folder's tile: the mosaic, the new episodes at the top right, the
/// start at the bottom right, the name and the number of shows.
struct PodcastFolderTile: View {
    let folder: MaerPlaylists.Playlist
    let newCount: Int
    let start: () -> Void
    @Environment(\.itemRouter) private var router
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlaylistArtwork(playlistID: folder.id,
                            coverURLs: PlaylistCardSource.deviceCovers(folder, router: router),
                            cornerRadius: 12)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if newCount > 0 {
                        StandardCoverMarks(count: newCount, coverSide: side)
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
                .lineLimit(1)
            Text("\(folder.itemIds.count) shows")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: side, alignment: .leading)
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
        .sheet(item: $editing) { folder in
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
        .taskOnPodcastChange(store.playlist(id: folderId)?.itemIds.joined(separator: ",") ?? "") {
            let entries = store.playlist(id: folderId)?.itemIds ?? []
            let shows = entries.compactMap(PodcastFolder.feedKey(of:)).compactMap(RoutinePlayback.show(feedKey:))
            let snapshot = PodcastSections.snapshot(shows: shows)
            let sections = await PodcastSections.computeDetached(shows: shows, snapshot: snapshot)
            infos = RecentShowInfo.inFolder(sections.recentShows, entries: entries)
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
                Text("Plays the newest unheard episode of each show, by date.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
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
