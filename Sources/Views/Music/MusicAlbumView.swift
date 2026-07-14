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

    private var tracks: [ABSChapter] { detail?.media.chapters ?? [] }
    /// Albums can be starred; playlists cannot.
    private var isAlbum: Bool { SubsonicProvider.id(item.id, kind: "album") != nil }

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
                                    .frame(width: 24, alignment: .trailing)
                                Text(track.title).lineLimit(1)
                                Spacer()
                                Text(Self.duration(track.end - track.start))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if loadFailed {
                ContentUnavailableView("Couldn't load tracks", systemImage: "music.note")
            } else {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .toolbar {
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
            }
        }
        .task(id: item.id) {
            await loadDetail()
            if isAlbum { starred = await SubsonicProvider.shared.isStarred(itemId: item.id) }
        }
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
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .scaleEffect(0.8)
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
            .frame(maxWidth: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 2) {
                Text(item.title).font(.title3.bold()).multilineTextAlignment(.center)
                if let artist = item.author {
                    Text(artist).foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await playerCoordinator.open(item: item) }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: 240)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(tracks.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
