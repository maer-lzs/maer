import SwiftUI

/// Shared building blocks for book grids: cell, Haptic Touch menu and the
/// author/genre browsing screens. Extracted from `LibraryView` so the browse
/// grids get exactly the same look and the same menu.

/// Status line below the cover ("Finished" / "x h left" / "x % listened").
@MainActor
func bookStatusText(_ p: BookProgress, duration: Double?) -> String {
    if p.isFinished { return String(localized: "Completed") }
    if p.isStarted {
        if let t = p.remainingText(bookDuration: duration) { return t }
        return String(localized: "\(p.fraction.formatted(.percent.precision(.fractionLength(0)))) listened")
    }
    return ""
}

// MARK: - Context menu (Haptic Touch)

/// Menu items: play, download control matching the phase, played status.
struct BookContextMenuItems: View {
    let entry: LibraryEntry
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    /// A7: offline, playing needs a download and starting a download is
    /// impossible — gate the menu entries consistently with the detail page.
    private var isOffline: Bool { !NetworkMonitor.shared.isConnected }

    var body: some View {
        // Play only when it can actually start (online, or downloaded).
        if !isOffline || DownloadManager.shared.isDownloaded(itemId: entry.id) {
            Button {
                Task { await playerCoordinator.open(item: entry.item) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
        }

        if DownloadManager.shared.isDownloaded(itemId: entry.id) {
            Button(role: .destructive) {
                DownloadManager.shared.deleteDownload(itemId: entry.id)
            } label: {
                Label("Delete Download", systemImage: "trash")
            }
        } else {
            // Mirror the detail page's download controls: a running or
            // paused download used to leave the menu without ANY download
            // entry — pause/resume/cancel work from the library too.
            switch DownloadManager.shared.phase[entry.id] {
            case .downloading:
                Button {
                    DownloadManager.shared.pauseDownload(itemId: entry.id)
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
                Button(role: .destructive) {
                    DownloadManager.shared.cancelDownload(itemId: entry.id)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            case .paused:
                Button {
                    DownloadManager.shared.resumeDownload(itemId: entry.id)
                } label: {
                    Label("Resume", systemImage: "play.circle")
                }
                Button(role: .destructive) {
                    DownloadManager.shared.cancelDownload(itemId: entry.id)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            case .failed, nil:
                if !isOffline {
                    Button {
                        Task { await quickDownload() }
                    } label: {
                        Label("Save for Offline", systemImage: "arrow.down.circle")
                    }
                }
            }
        }

        Button {
            Task { await quickToggleFinished() }
        } label: {
            let isFinished = entry.progress?.isFinished ?? false
            Label(
                isFinished ? String(localized: "Mark as Unfinished") : String(localized: "Mark as Finished"),
                systemImage: isFinished ? "checkmark.circle.fill" : "checkmark.circle"
            )
        }
    }

    /// Briefly loads the track info (the list itself only has the slim metadata)
    /// and then starts the download — without a Wi-Fi prompt, deliberately the
    /// quick variant for the context menu here.
    private func quickDownload() async {
        guard let detail = try? await playerCoordinator.provider.fetchItemDetail(itemId: entry.id) else { return }
        await DownloadManager.shared.download(item: detail, provider: playerCoordinator.provider)
    }

    /// As in BookDetailScreen: always send the complete record (currentTime +
    /// duration + isFinished), never the flag alone — otherwise the real progress
    /// is lost (see sync bugfix).
    private func quickToggleFinished() async {
        let provider = playerCoordinator.provider
        let newIsFinished = !(entry.progress?.isFinished ?? false)
        let duration: Double
        let currentTime: Double
        if let fresh = try? await provider.fetchItemDetail(itemId: entry.id) {
            duration = fresh.media.duration ?? 0
            currentTime = fresh.userMediaProgress?.currentTime ?? 0
        } else {
            // Offline/error: locally known values instead of a silent abort.
            duration = entry.item.media?.duration ?? 0
            currentTime = (entry.progress?.fraction ?? 0) * duration
        }
        do {
            try await provider.updateProgress(
                itemId: entry.id,
                currentTime: newIsFinished ? duration : currentTime,
                duration: duration,
                isFinished: newIsFinished
            )
        } catch {
            // Don't lose the status decision: queue it, the flush sends it later.
            SyncQueue.shared.enqueue(
                itemId: entry.id,
                currentTime: newIsFinished ? duration : currentTime,
                duration: duration,
                isFinished: newIsFinished
            )
        }
        await libraryViewModel.refreshProgress()
    }
}

/// Lifted force-press preview on our adaptive glass instead of the plain
/// system platter, so it matches the rest of the chrome. Deliberately
/// NEUTRAL glass: the shared accent belongs to the PLAYING book, not the
/// pressed one.
struct BookContextPreview: View {
    let entry: LibraryEntry
    let provider: any AudioProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BookCoverView(
                url: AppSession.shared.coverURL(forItemId: entry.id),
                progress: entry.progress,
                itemId: entry.id,
                size: 240
            )
            Text(entry.item.title)
                .font(.headline)
                .lineLimit(2)
            if let author = entry.item.author {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let p = entry.progress {
                Text(bookStatusText(p, duration: entry.item.media?.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 240)
        .padding(20)
        .modifier(AdaptiveGlassBackground(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)))
        .environment(\.glassAccent, nil)
        // Room for the glass shadow — the preview is snapshotted at its bounds.
        .padding(12)
    }
}

/// Attaches menu + glass preview to any book cell.
struct BookCellContextMenu: ViewModifier {
    let entry: LibraryEntry
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    func body(content: Content) -> some View {
        content.contextMenu {
            BookContextMenuItems(
                entry: entry,
                playerCoordinator: playerCoordinator,
                libraryViewModel: libraryViewModel
            )
        } preview: {
            BookContextPreview(entry: entry, provider: playerCoordinator.provider)
        }
    }
}

// MARK: - Grid cell

/// A book cell (cover + title + author + status) incl. navigation to the detail
/// page and Haptic Touch menu — identical in library and browse.
struct BookGridCell: View {
    let entry: LibraryEntry
    let width: CGFloat
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    var body: some View {
        // Value-based navigation (instead of closure-based) so a reset of the
        // navigationPath — e.g. tapping a media tab — pops the detail cleanly
        // back to the library root. Target: the shared
        // navigationDestination(for: String.self) in LibraryView.
        NavigationLink(value: entry.id) {
            VStack(alignment: .leading, spacing: 6) {
                BookCoverView(
                    url: AppSession.shared.coverURL(forItemId: entry.id),
                    progress: entry.progress,
                    itemId: entry.id,
                    size: width
                )
                Text(entry.item.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let author = entry.item.author {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let p = entry.progress {
                    Text(bookStatusText(p, duration: entry.item.media?.duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: width, alignment: .leading)
            // Top-align within the grid row: LazyVGrid sizes each row to its
            // tallest cell and CENTERS shorter ones — covers of cells with
            // less text would sit visibly lower than their neighbours.
            .frame(maxHeight: .infinity, alignment: .top)
            // VoiceOver: one stop per book (title, author, status together)
            // instead of stepping through cover, texts, and badges separately.
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        // Sibling overlay over the cover area so the ring's cancel button wins
        // the hit over the navigation link underneath.
        .overlay(alignment: .top) {
            DownloadInstallRing(itemId: entry.id)
                .frame(width: width, height: width)
        }
        .modifier(BookCellContextMenu(
            entry: entry,
            playerCoordinator: playerCoordinator,
            libraryViewModel: libraryViewModel
        ))
    }
}

// MARK: - Browse grid

/// Cover grid of a group — measures its own width and uses the same column math
/// as the library (see the LibraryView comment).
struct BrowseBooksScreen: View {
    let title: String
    let entries: [LibraryEntry]
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    @State private var measuredWidth: CGFloat = 0

    private let minColumnWidth: CGFloat = 108
    private let gridSpacing: CGFloat = 16
    private let horizontalPadding: CGFloat = 16

    private var columnCount: Int {
        guard measuredWidth > 0 else { return 3 }
        let available = measuredWidth - horizontalPadding * 2
        return max(Int((available + gridSpacing) / (minColumnWidth + gridSpacing)), 1)
    }

    private var cellWidth: CGFloat {
        guard measuredWidth > 0 else { return 132 }
        let available = measuredWidth - horizontalPadding * 2
        let totalSpacing = gridSpacing * CGFloat(columnCount - 1)
        return (available - totalSpacing) / CGFloat(columnCount)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount),
                alignment: .leading,
                spacing: 20
            ) {
                ForEach(entries) { entry in
                    BookGridCell(
                        entry: entry,
                        width: cellWidth,
                        playerCoordinator: playerCoordinator,
                        libraryViewModel: libraryViewModel
                    )
                }
            }
            .padding(.horizontal)
            .bottomBarClearance()
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { measuredWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newWidth in
                        measuredWidth = newWidth
                    }
            }
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Downloaded-audiobook row — mirrors the podcast episode row (same
/// `MediaRowContent` layout + a large play button, tap opens the detail page)
/// so the audiobook "Downloaded" section reads and behaves like the podcast
/// pendant (Regel 2).
struct BookDownloadRow: View {
    let entry: LibraryEntry
    @ObservedObject var playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel
    @ObservedObject private var downloads = DownloadManager.shared

    private var isCurrent: Bool { playerCoordinator.activeItem?.id == entry.id }
    private var isPlayingThis: Bool { isCurrent && playerCoordinator.isPlaying }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Row body opens the detail page. LazyVStack context → a
            // NavigationLink draws no disclosure chevron (unlike a List).
            NavigationLink(value: entry.id) {
                MediaRowContent(
                    coverURL: AppSession.shared.coverURL(forItemId: entry.id),
                    eyebrow: entry.item.author,
                    title: entry.item.title,
                    downloadedBadge: downloads.isDownloaded(itemId: entry.id),
                    progressFraction: (entry.progress?.isStarted == true) ? entry.progress?.fraction : nil,
                    meta: entry.progress.map { bookStatusText($0, duration: entry.item.media?.duration) },
                    placeholderSystemImage: "book.closed"
                )
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            playButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .modifier(BookCellContextMenu(
            entry: entry, playerCoordinator: playerCoordinator, libraryViewModel: libraryViewModel))
    }

    private var playButton: some View {
        Button {
            if isPlayingThis { playerCoordinator.viewModel?.pause() }
            else if isCurrent { playerCoordinator.viewModel?.play() }
            else { Task { await playerCoordinator.open(item: entry.item) } }
        } label: {
            Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlayingThis ? Text("Pause") : Text("Play"))
    }
}
