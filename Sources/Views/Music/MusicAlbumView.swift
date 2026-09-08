// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import OSLog

/// Album (or playlist) detail: cover header + track list. Tapping a track plays
/// the whole album from that song (album = one multi-track item, songs are
/// chapters). Works for both `sub:album:` and `sub:playlist:` items.
struct MusicAlbumView: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var downloadManager = DownloadManager.shared

    @State private var detail: LibraryItemDetail?
    /// How the detail load ended when it did not succeed. The loading
    /// state is never an end state: a failure names itself and offers the
    /// honest next step (retry, or for an item the source withdrew, the
    /// EXPLICIT removal from Listen Again; never a silent delete).
    enum LoadFailure { case transport(reason: String), gone, empty }
    @State private var loadFailure: LoadFailure?
    @State private var starred = false
    /// Album notes/description from getAlbumInfo2 (expandable).
    @State private var albumNotes: String?
    @State private var notesExpanded = false
    /// High-res front cover from the Cover Art Archive (via release MBID).
    @State private var highResCover: UIImage?
    /// Flip re-runs the load task. Off drops the CAA image
    /// IMMEDIATELY (server cover shows), cached files stay for re-enable.
    @AppStorage(AppStorageKeys.musicHighResCovers) private var hiResCovers = true
    /// Package 1: the single song a user long-pressed to add to a playlist.
    /// Playlist header shows the F5 2×2 mosaic (same component as the cards),
    /// not a single server cover. Up to four distinct album covers.
    @State private var mosaicCoverURLs: [URL] = []
    /// Track-number column scales with Dynamic Type.
    @ScaledMetric(relativeTo: .subheadline) private var trackNumberWidth: CGFloat = 24

    private var tracks: [ABSChapter] { detail.map { Self.trackList(of: $0).chapters } ?? [] }

    /// The track list of a detail, pure: the chapters when the source
    /// states them (a server album), else one chapter per audio track
    /// (a catalogue release carries its songs as tracks and states no
    /// chapters; E89: the page read only the chapters and stayed on
    /// "Loading" for every netlabel album although the answer had
    /// arrived). `source` names which one, for the log.
    nonisolated static func trackList(of detail: LibraryItemDetail) -> (chapters: [ABSChapter], source: String) {
        if let chapters = detail.media.chapters, !chapters.isEmpty { return (chapters, "chapters") }
        let audio = detail.media.tracks ?? []
        guard !audio.isEmpty else { return ([], "none") }
        let duration = detail.media.duration ?? audio.compactMap(\.duration).reduce(0, +)
        return (ChapterModel.trackChapters(audio, duration: duration), "tracks")
    }
    /// Track indices ranked by play count (pure, tested); empty hides
    /// the section. Reads the provider's per-detail cache. Plain read.
    private var topSongIndices: [Int] {
        guard detail != nil else { return [] }
        return MusicPopularity.topIndices(
            playCounts: AppSession.shared.musicProvider.trackPlayCounts(forItemId: item.id))
    }
    // Playlist basics: rename/delete with confirmation; server truth = reload.
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) private var dismissView
    @Environment(\.isOnline) private var isOnline
    /// Albums can be starred; playlists cannot.
    private var isAlbum: Bool { AppSession.shared.musicProvider.kind(of: item.id) == .album }
    /// Playlists get the mosaic header; albums keep their single cover.
    private var isPlaylist: Bool { AppSession.shared.musicProvider.kind(of: item.id) == .playlist }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            // Client-side "Top Songs" over the play counts the detail
            // already carries. Small section ABOVE the track list, hidden
            // silently when the server ships no counts (plain Subsonic).
            if !topSongIndices.isEmpty {
                Section {
                    ForEach(Array(topSongIndices.enumerated()), id: \.element) { rank, trackIndex in
                        if tracks.indices.contains(trackIndex) {
                            Button {
                                Task { await play(fromTrackAt: tracks[trackIndex].start) }
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(rank + 1)")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: trackNumberWidth, alignment: .trailing)
                                    Text(tracks[trackIndex].title).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "play.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    // Per-user play counts. Labeled as PERSONAL.
                    Text("Your most played")
                }
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
                        // Playlist basics: remove THIS row (index-precise.
                        // A duplicated song removes only this position).
                        .swipeActions(edge: .trailing) {
                            if isPlaylist {
                                Button(role: .destructive) {
                                    Task {
                                        try? await AppSession.shared.musicProvider
                                            .removeSongs(at: [index], fromPlaylistItemId: item.id)
                                        await loadDetail()
                                    }
                                } label: { Label("Remove from Playlist", systemImage: "minus.circle") }
                            }
                        }
                        // Song long-press. Play from here + album download
                        // (music downloads are per album).
                        .contextMenu {
                            Button {
                                Task { await play(fromTrackAt: track.start) }
                            } label: { Label("Play from Here", systemImage: "play.fill") }
                            // Single songs join the global Up-Next queue.
                            // Same actions as book/podcast/album menus.
                            Button {
                                Task {
                                    let music = AppSession.shared.musicProvider
                                    if let songId = await music.songId(forItemId: item.id, trackIndex: index) {
                                        PlayQueue.shared.playNext(music.itemId(songId: songId))
                                    }
                                }
                            } label: { Label("Play Next", systemImage: "text.insert") }
                            Button {
                                Task {
                                    let music = AppSession.shared.musicProvider
                                    if let songId = await music.songId(forItemId: item.id, trackIndex: index) {
                                        PlayQueue.shared.playLast(music.itemId(songId: songId))
                                    }
                                }
                            } label: { Label("Play Last", systemImage: "text.append") }
                            // The track's own address is only known after the
                            // server answered. The shared action takes a
                            // resolver so this row needs no second copy.
                            AddToPlaylistButton(itemId: item.id) {
                                let music = AppSession.shared.musicProvider
                                guard let songId = await music.songId(forItemId: item.id,
                                                                      trackIndex: index) else {
                                    return ([], [:])
                                }
                                let songItemId = music.itemId(songId: songId)
                                return ([songItemId], [songItemId: track.title])
                            }
                            if downloadManager.isDownloaded(itemId: item.id) {
                                Button(role: .destructive) {
                                    downloadManager.deleteDownload(itemId: item.id)
                                } label: { Label("Delete Download", systemImage: "trash") }
                            } else if let detail, isOnline {
                                Button {
                                    Task { await downloadManager.download(item: detail, provider: AppSession.shared.subsonicProvider) }
                                } label: { Label("Download Album", systemImage: "arrow.down.circle") }
                            }
                        }
                    }
                }
            } else if let failure = loadFailure {
                switch failure {
                case .gone:
                    // Measured (metadata answers error/404), not guessed: the
                    // source withdrew the item. The mark also keeps it out of
                    // the curated rows (the existing dead-items ladder).
                    ContentUnavailableView {
                        Label("No longer available at the source", systemImage: "music.note")
                    } description: {
                        Text("The source has withdrawn this item. Your listening mark stays until you remove it.")
                    } actions: {
                        Button(role: .destructive) {
                            // The user's explicit click, never silent: the
                            // ONE legitimate removal (the item itself is
                            // gone, so its state has nothing left to belong
                            // to), and Listen Again lets go of the tile.
                            ListeningStore.forgetUserDeleted(item.id)
                        } label: {
                            Text("Remove from Listen Again")
                        }
                        .accessibilityIdentifier("album-remove-from-listen-again")
                    }
                case .transport(let reason):
                    ContentUnavailableView {
                        Label("Couldn't load tracks", systemImage: "music.note")
                    } description: {
                        // The reason is measured, not guessed: the status or
                        // the transport error the source answered with.
                        Text("This could not be loaded. Check your connection.")
                            + Text(verbatim: reason.isEmpty ? "" : " (\(reason))")
                    } actions: {
                        Button("Try Again") { Task { await loadDetail() } }
                    }
                case .empty:
                    // The source answered, and named no track: an end
                    // state of its own, never the loading state.
                    ContentUnavailableView {
                        Label("No tracks", systemImage: "music.note")
                    } description: {
                        Text("The source answered without any audio track for this item.")
                    } actions: {
                        Button("Try Again") { Task { await loadDetail() } }
                    }
                }
            } else {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            }
            // Album notes (best-effort from getAlbumInfo2). Expandable.
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
        .toolbar {
            // Page actions inboard, the settings cog OUTERMOST. Declared
            // last so it sits at the trailing edge and never vanishes behind
            // download/favorite (the root cog doesn't propagate to pushed pages).
            ToolbarItemGroup(placement: .topBarTrailing) {
                downloadButton
                if isAlbum {
                    Button {
                        Task { starred = await AppSession.shared.musicProvider.toggleStar(itemId: item.id) }
                    } label: {
                        Image(systemName: starred ? "heart.fill" : "heart")
                    }
                    .tint(starred ? .red : nil)
                }
                if isPlaylist {
                    Menu {
                        Button {
                            renameText = item.title
                            showRename = true
                        } label: { Label("Rename Playlist", systemImage: "pencil") }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: { Label("Delete Playlist", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("playlist-actions")
                }
            }
        }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                Task {
                    try? await AppSession.shared.musicProvider
                        .renamePlaylist(itemId: item.id, newName: renameText)
                    await loadDetail()
                    // Server truth: the tab's playlist row re-reads the list.
                    AppSession.shared.musicProvider.librarySynced.send()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this playlist?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                Task {
                    try? await AppSession.shared.musicProvider.deletePlaylist(itemId: item.id)
                    AppSession.shared.musicProvider.librarySynced.send()
                    dismissView()
                }
            }
        }
        .task(id: "\(item.id)-\(hiResCovers)") {
            if !hiResCovers { highResCover = nil }
            await loadDetail()
            if isPlaylist {
                // Same mosaic path as the cards. No second artwork builder.
                let music = AppSession.shared.musicProvider
                let ids = await music.playlistMosaicCoverIDs(forItemId: item.id)
                mosaicCoverURLs = ids.compactMap { music.coverURL(coverArtId: $0) }
            }
            if isAlbum {
                starred = await AppSession.shared.musicProvider.isStarred(itemId: item.id)
                // Notes + (via release MBID) a high-res cover. Both
                // best-effort, on demand only.
                let info = await AppSession.shared.musicProvider.albumInfo(itemId: item.id)
                albumNotes = Self.stripped(info?.notes)
                if let mbid = info?.musicBrainzId, !mbid.isEmpty {
                    highResCover = await CoverArtArchive.shared.frontCover(mbid: mbid)
                }
            }
        }
    }

    /// Album notes often carry HTML fragments. Strip tags for display.
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
            // Show the actual progress (ring) instead of a bare stop icon;
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
                // A playlist shows the F5 2×2 mosaic. The same component as the
                // cards/rows, not the server's single playlist cover.
                if isPlaylist {
                    PlaylistArtwork(playlistID: item.id, coverURLs: mosaicCoverURLs)
                        // Own 2:3 ratio (Kursänderung). No square override.

                } else if let highResCover {
                    // Prefer the high-res Cover Art Archive front when loaded.
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
                // Year · genre where the server provides them.
                let meta = [detail?.media.metadata?.publishedYear?.value,
                            detail?.media.metadata?.genres?.first]
                    .compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                playButton
                // Shuffle this album/playlist. Same button/component as the
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

    /// Matches the primary-play family. A WHITE control glyph on the
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

    /// The shared capsule look for the album header's play control. White glyph
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
        loadFailure = nil
        do {
            let fetched = try await AppSession.shared.provider(for: item.id).fetchItemDetail(itemId: item.id)
            detail = fetched
            // Every exit an end state: tracks, or "no tracks" said as such.
            // "Loading" never survives an answer.
            let list = Self.trackList(of: fetched)
            if list.chapters.isEmpty {
                loadFailure = .empty
                Logger.library.notice("ALBUM detail empty ns=\(ItemNamespace.of(item.id) ?? "-", privacy: .public)")
            } else {
                Logger.library.notice("ALBUM detail set tracks=\(list.chapters.count) source=\(list.source, privacy: .public) ns=\(ItemNamespace.of(item.id) ?? "-", privacy: .public)")
            }
        } catch {
            // Cancellation is not a failure: the page's task is bound to
            // the item, and the next appearance fetches again. It is said
            // in the log, so a page that stays on "Loading" can be read.
            guard !error.isCancellation else {
                Logger.library.notice("ALBUM detail cancelled ns=\(ItemNamespace.of(item.id) ?? "-", privacy: .public)")
                return
            }
            let reason = FreeCatalog.failureReason(error) ?? ""
            // Tell "withdrawn" apart from "unreachable" by MEASURING, with
            // the one existing ladder: only a reachable service that
            // answers error/404 for the item means gone; a network failure
            // says nothing about the item and keeps the retry path.
            if item.id.hasPrefix(FreeCatalog.archivePrefix) {
                let identifier = FreeCatalog.archiveIdentifier(of: item.id) ?? item.id
                let liveness = await ArchiveOrgClient.liveness(identifier: identifier)
                DeadCatalogItems.note(liveness, for: item.id)
                loadFailure = liveness == .dead ? .gone : .transport(reason: reason)
            } else {
                loadFailure = .transport(reason: reason)
            }
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

/// Header play control while THIS album is the active session. Observes the
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
