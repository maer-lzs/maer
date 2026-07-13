import SwiftUI

/// Music tab (Subsonic/Navidrome). Media-type-specific layout, deliberately not
/// the audiobook grid: shelves on top (recently added, most played), browse rows
/// for artists/playlists, then the full album grid. Tapping an album opens its
/// track list; playback runs through the shared player.
struct MusicView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @StateObject private var vm = MusicViewModel()

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        Group {
            // Full-screen error ONLY when there is nothing to show — a failed
            // refresh must never displace the already-loaded library (stale
            // beats empty, like the book library).
            if let error = vm.errorText, vm.albums.isEmpty {
                ContentUnavailableView {
                    Label("Music unavailable", systemImage: "music.note")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await vm.reload() } }
                }
            } else if vm.albums.isEmpty && vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if vm.albums.isEmpty {
                ContentUnavailableView("No music", systemImage: "music.note")
            } else {
                ScrollView { content }
                    .bottomBarClearance()
            }
        }
        .task { await vm.loadIfNeeded() }
        // Lift the work into its own task: .refreshable cancels ITS task when
        // the bounce settles — that used to abort the request and surface a
        // fake error page.
        .refreshable { await Task { await vm.reload() }.value }
    }

    private var content: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            // Inline hint when a refresh failed but content is still shown.
            if let error = vm.errorText {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            if !vm.newest.isEmpty { shelf("Recently Added", vm.newest) }
            if !vm.frequent.isEmpty { shelf("Most Played", vm.frequent) }

            if !vm.artists.isEmpty || !vm.playlists.isEmpty {
                VStack(spacing: 0) {
                    if !vm.artists.isEmpty {
                        browseRow("Artists", systemImage: "music.mic") {
                            MusicArtistsView(artists: vm.artists, playerCoordinator: playerCoordinator)
                        }
                    }
                    if !vm.playlists.isEmpty {
                        Divider().padding(.leading, 52)
                        browseRow("Playlists", systemImage: "music.note.list") {
                            MusicPlaylistsView(playlists: vm.playlists, playerCoordinator: playerCoordinator)
                        }
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }

            Text("Albums").font(.title3).bold().padding(.horizontal)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(vm.albums) { album in
                    AlbumCell(item: album, playerCoordinator: playerCoordinator)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
    }

    private func shelf(_ title: LocalizedStringKey, _ items: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        AlbumCell(item: item, width: 150, playerCoordinator: playerCoordinator)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func browseRow<Destination: View>(
        _ title: LocalizedStringKey, systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            Label(title, systemImage: systemImage)
                .padding(.vertical, 12)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Square album tile → album detail. Reused by shelves and the grid.
struct AlbumCell: View {
    let item: LibraryItem
    var width: CGFloat? = nil
    @ObservedObject var playerCoordinator: PlayerCoordinator

    var body: some View {
        NavigationLink {
            MusicAlbumView(item: item, playerCoordinator: playerCoordinator)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CachedAsyncImage(
                    url: AppSession.shared.coverURL(forItemId: item.id),
                    useThumbnail: true, thumbnailMaxPixel: 400
                ) { image in
                    image.resizable().aspectRatio(1, contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(width: width)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(item.title).font(.subheadline).lineLimit(1)
                if let artist = item.author {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
