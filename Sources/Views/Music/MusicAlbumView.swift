// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Album (or playlist) detail: cover header + track list. Tapping a track plays
/// the whole album from that song (album = one multi-track item, songs are
/// chapters). Works for both `sub:album:` and `sub:playlist:` items.
struct MusicAlbumView: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var downloadManager = DownloadManager.shared

    @State private var detail: LibraryItemDetail?
    @State private var loadFailed = false
    @State private var starred = false
    /// M3: album notes/description from getAlbumInfo2 (expandable).
    @State private var albumNotes: String?
    @State private var notesExpanded = false
    /// M6: high-res front cover from the Cover Art Archive (via release MBID).
    @State private var highResCover: UIImage?
    /// Package 1: the single song a user long-pressed to add to a playlist.
    @State private var addTarget: AddToPlaylistTarget?
    /// Playlist header shows the F5 2×2 mosaic (same component as the cards),
    /// not a single server cover — up to four distinct album covers.
    @State private var mosaicCoverURLs: [URL] = []
    /// D12/B11: track-number column scales with Dynamic Type.
    @ScaledMetric(relativeTo: .subheadline) private var trackNumberWidth: CGFloat = 24

    private var tracks: [ABSChapter] { detail?.media.chapters ?? [] }
    /// Albums can be starred; playlists cannot.
    private var isAlbum: Bool { SubsonicProvider.id(item.id, kind: "album") != nil }
    /// Playlists get the mosaic header; albums keep their single cover.
    private var isPlaylist: Bool { SubsonicProvider.id(item.id, kind: "playlist") != nil }
    private var playlistRawId: String { SubsonicProvider.id(item.id, kind: "playlist") ?? item.id }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if !tracks.isEmpty {
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            Task { await play(fromTrackAt: track.start) }
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: trackNumberWidth, alignment: .trailing)
                                Text(track.title).lineLimit(1)
                                Spacer()
                                Text(Self.duration(track.end - track.start))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // S18: song long-press — play from here + album download
                        // (music downloads are per album).
                        .contextMenu {
                            Button {
                                Task { await play(fromTrackAt: track.start) }
                            } label: { Label("Play from Here", systemImage: "play.fill") }
                            Button {
                                Task {
                                    if let songId = await AppSession.shared.subsonicProvider.songId(forItemId: item.id, trackIndex: index) {
                                        addTarget = AddToPlaylistTarget(itemId: SubsonicProvider.itemId(songId: songId))
                                    }
                                }
                            } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
                            if downloadManager.isDownloaded(itemId: item.id) {
                                Button(role: .destructive) {
                                    downloadManager.deleteDownload(itemId: item.id)
                                } label: { Label("Delete Download", systemImage: "trash") }
                            } else if let detail, NetworkMonitor.shared.isConnected {
                                Button {
                                    Task { await downloadManager.download(item: detail, provider: AppSession.shared.subsonicProvider) }
                                } label: { Label("Download Album", systemImage: "arrow.down.circle") }
                            }
                        }
                    }
                }
            } else if loadFailed {
                ContentUnavailableView("Couldn't load tracks", systemImage: "music.note")
            } else {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            }
            // M3: album notes (best-effort from getAlbumInfo2) — expandable.
            if let albumNotes {
                Section {
                    Text(albumNotes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(notesExpanded ? nil : 4)
                        .onTapGesture { withAnimation { notesExpanded.toggle() } }
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .barAwareList()
        .addToPlaylistSheet(target: $addTarget)
        .toolbar {
            // Y63: page actions inboard, the settings cog OUTERMOST — declared
            // last so it sits at the trailing edge and never vanishes behind
            // download/favorite (the root cog doesn't propagate to pushed pages).
            ToolbarItemGroup(placement: .topBarTrailing) {
                downloadButton
                if isAlbum {
                    Button {
                        Task { starred = await SubsonicProvider.shared.toggleStar(itemId: item.id) }
                    } label: {
                        Image(systemName: starred ? "heart.fill" : "heart")
                    }
                    .tint(starred ? .red : nil)
                }
                SettingsToolbarButton()
            }
        }
        .task(id: item.id) {
            await loadDetail()
            if isPlaylist {
                // Same mosaic path as the cards — no second artwork builder.
                let ids = await SubsonicProvider.shared.playlistMosaicCoverIDs(playlistRawId: playlistRawId)
                mosaicCoverURLs = ids.compactMap { SubsonicProvider.shared.subsonicCoverURL(coverArtId: $0) }
            }
            if isAlbum {
                starred = await SubsonicProvider.shared.isStarred(itemId: item.id)
                // M3/M6: notes + (via release MBID) a high-res cover — both
                // best-effort, on demand only.
                let info = await SubsonicProvider.shared.albumInfo(itemId: item.id)
                albumNotes = Self.stripped(info?.notes)
                if let mbid = info?.musicBrainzId, !mbid.isEmpty {
                    highResCover = await CoverArtArchive.shared.frontCover(mbid: mbid)
                }
            }
        }
    }

    /// Album notes often carry HTML fragments — strip tags for display.
    private static func stripped(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let text = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    @ViewBuilder
    private var downloadButton: some View {
        if downloadManager.isDownloaded(itemId: item.id) {
            Button(role: .destructive) {
                downloadManager.deleteDownload(itemId: item.id)
            } label: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
            }
        } else if case .downloading(let fraction) = downloadManager.phase[item.id] {
            // A8: show the actual progress (ring) instead of a bare stop icon;
            // tapping still cancels.
            Button {
                downloadManager.cancelDownload(itemId: item.id)
            } label: {
                DownloadRing(fraction: fraction)
            }
        } else if let detail {
            Button {
                Task { await downloadManager.download(item: detail, provider: AppSession.shared.subsonicProvider) }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Group {
                // A playlist shows the F5 2×2 mosaic — the same component as the
                // cards/rows, not the server's single playlist cover.
                if isPlaylist {
                    PlaylistArtwork(playlistID: playlistRawId, coverURLs: mosaicCoverURLs)
                        .aspectRatio(1, contentMode: .fit)
                } else if let highResCover {
                    // M6: prefer the high-res Cover Art Archive front when loaded.
                    Image(uiImage: highResCover)
                        .resizable().aspectRatio(1, contentMode: .fit)
                } else {
                    CachedAsyncImage(
                        url: AppSession.shared.coverURL(forItemId: item.id),
                        useThumbnail: true, thumbnailMaxPixel: 600
                    ) { image in
                        image.resizable().aspectRatio(1, contentMode: .fit)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary))
                    }
                }
            }
            .frame(maxWidth: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 2) {
                Text(item.title).font(.title3.bold()).multilineTextAlignment(.center)
                if let artist = item.author {
                    Text(artist).foregroundStyle(.secondary)
                }
                // M3: year · genre where the server provides them.
                let meta = [detail?.media.metadata?.publishedYear?.value,
                            detail?.media.metadata?.genres?.first]
                    .compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                playButton
                // Shuffle this album/playlist — same button/component as the
                // music-tab root, icon style beside the primary play control.
                ShufflePlayButton(playerCoordinator: playerCoordinator, style: .icon) {
                    await AppSession.shared.subsonicProvider.songItems(forItemId: item.id)
                }
                .font(.title3)
                .disabled(tracks.isEmpty)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Y40/Y47: matches the primary-play family — a WHITE control glyph on the
    /// accent capsule (not `.borderedProminent`, whose tint reads gray now), and
    /// it flips Play↔Pause while THIS album is the active session. Like the book
    /// detail button (see `ActivePlayButton`) the active case lives in a subview
    /// that observes the view model directly, since the coordinator only
    /// republishes when `viewModel` is re-set, not on play/pause within it.
    @ViewBuilder
    private var playButton: some View {
        if let vm = playerCoordinator.viewModel, playerCoordinator.activeItem?.id == item.id {
            ActiveAlbumPlayButton(viewModel: vm)
                .disabled(tracks.isEmpty)
        } else {
            Button {
                Task { await playerCoordinator.open(item: item) }
            } label: {
                Self.playCapsule(title: String(localized: "Play"), systemImage: "play.fill")
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
        }
    }

    /// The shared capsule look for the album header's play control — white glyph
    /// and label on the accent fill.
    static func playCapsule(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: 240)
            .padding(.vertical, 12)
            .background(AppTheme.accent, in: Capsule())
    }

    private func loadDetail() async {
        loadFailed = false
        do {
            detail = try await AppSession.shared.provider(for: item.id).fetchItemDetail(itemId: item.id)
        } catch {
            loadFailed = true
        }
    }

    /// Plays the album and jumps to the song at `start` (its chapter offset).
    private func play(fromTrackAt start: Double) async {
        await playerCoordinator.open(item: item)
        await playerCoordinator.viewModel?.seek(to: start)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Header play control while THIS album is the active session — observes the
/// view model directly so it flips Play↔Pause reactively (Y47).
private struct ActiveAlbumPlayButton: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        Button {
            viewModel.togglePlayPause()
        } label: {
            MusicAlbumView.playCapsule(
                title: viewModel.isPlaying ? String(localized: "Pause") : String(localized: "Play"),
                systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.plain)
    }
}
