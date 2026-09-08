// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Shared building blocks for book grids: cell, Haptic Touch menu and the
/// author/genre browsing screens. Extracted from `LibraryView` so the browse
/// grids get exactly the same look and the same menu.

/// Status line below the cover ("Finished" / "x h left" / "x % listened").
@MainActor
func bookStatusText(_ p: BookProgress, duration: Double?) -> String {
    if p.countsAsFinished { return String(localized: "Completed") }
    if p.isStarted {
        if let t = p.remainingText(bookDuration: duration) { return t }
        return String(localized: "\(p.fraction.formatted(.percent.precision(.fractionLength(0)))) listened")
    }
    return ""
}

/// The third line is ALWAYS filled. A mixed
/// line made the time vanish for the ~95 % unstarted majority. Started →
/// remaining ("4 hr 57 min left"); unstarted → the TOTAL duration
/// ("8 hr 41 min"); finished → Completed. No empty reserve possible, and a
/// runtime→remaining switch only changes TEXT, never height. Pure.
nonisolated func bookTimeLine(progress: BookProgress?, duration: Double?) -> String {
    if let progress {
        if progress.countsAsFinished { return String(localized: "Completed") }
        if progress.isStarted, let t = progress.remainingText(bookDuration: duration) { return t }
    }
    guard let duration, duration > 0 else { return " " }
    let totalMinutes = Int(duration) / 60
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 { return String(localized: "\(hours) hr \(minutes) min") }
    return String(localized: "\(minutes) min")
}

// MARK: - Context menu (Haptic Touch)

/// Menu items: play, download control matching the phase, played status.
struct BookContextMenuItems: View {
    let entry: LibraryEntry
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel
    /// Only the CONTINUE rows offer "don't show here any more".
    /// In the library grid the entry would be meaningless (the book is not
    /// there because of Continue). The row decides, not the card.
    var showsContinueHide = false

    /// Offline, playing needs a download and starting a download is
    /// impossible. Gate the menu entries consistently with the detail page.
    @Environment(\.isOnline) private var isOnline
    private var isOffline: Bool { !isOnline }

    var body: some View {
        // Play only when it can actually start (online, or downloaded).
        if !isOffline || DownloadManager.shared.isDownloaded(itemId: entry.id) {
            Button {
                Task { await playerCoordinator.open(item: entry.item) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            // Global Up-Next queue. Same actions as the podcast/music menus.
            Button {
                PlayQueue.shared.playNext(entry.id)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            AddToPlaylistButton(itemId: entry.id,
                                knownTitles: [entry.id: entry.item.title])
            Button {
                PlayQueue.shared.playLast(entry.id)
            } label: {
                Label("Play Last", systemImage: "text.append")
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
            // entry. Pause/resume/cancel work from the library too.
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
            let isFinished = entry.progress?.countsAsFinished ?? false
            Label(
                isFinished ? String(localized: "Mark as Unfinished") : String(localized: "Mark as Finished"),
                systemImage: isFinished ? "checkmark.circle.fill" : "checkmark.circle"
            )
        }
        if showsContinueHide {
            Divider()
            Button {
                ContinueHiddenStore.hide(id: entry.id,
                                         lastUpdate: entry.progress?.lastUpdate ?? 0)
            } label: {
                // Says exactly what happens. And what does NOT happen.
                Label("Don't show under Continue", systemImage: "eye.slash")
            }
        }
    }

    /// Briefly loads the track info (the list itself only has the slim metadata)
    /// and then starts the download. Without a Wi-Fi prompt, deliberately the
    /// quick variant for the context menu here.
    private func quickDownload() async {
        guard let detail = try? await playerCoordinator.provider.fetchItemDetail(itemId: entry.id) else { return }
        await DownloadManager.shared.download(item: detail, provider: playerCoordinator.provider)
    }

    /// As in BookDetailScreen: always send the complete record (currentTime +
    /// duration + isFinished), never the flag alone. Otherwise the real progress
    /// is lost (see sync bugfix).
    private func quickToggleFinished() async {
        let provider = playerCoordinator.provider
        let newIsFinished = !(entry.progress?.isFinished ?? false)
        // Invariant "heard = flies out": marking finished drops it from Up Next.
        if newIsFinished { PlayQueue.shared.markedPlayed(entry.id) }
        // GT 09.08.: the player consequence belongs at the same place as the
        // queue invariant (X16c: mark = as if it had ended → stop and
        // auto-continue). No-op when the book is not the active item, so the
        // context menu needs no condition of its own.
        if newIsFinished { playerCoordinator.markPlayedAndAdvance(itemId: entry.id) }
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
        // Solid adaptive surface instead of glass. The preview is
        // snapshotted over arbitrary backdrops, where glass sampled noise.
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(12)
    }
}

/// Attaches menu + glass preview to any book cell.
struct BookCellContextMenu: ViewModifier {
    let entry: LibraryEntry
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel
    var showsContinueHide = false

    func body(content: Content) -> some View {
        content.contextMenu {
            BookContextMenuItems(
                entry: entry,
                playerCoordinator: playerCoordinator,
                libraryViewModel: libraryViewModel,
                showsContinueHide: showsContinueHide
            )
        } preview: {
            BookContextPreview(entry: entry, provider: playerCoordinator.provider)
        }
    }
}

// MARK: - Grid cell

/// A book cell (cover + title + author + status) incl. navigation to the detail
/// page and Haptic Touch menu. Identical in library and browse.
struct BookGridCell: View {
    let entry: LibraryEntry
    let width: CGFloat
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    var body: some View {
        // Value-based navigation (instead of closure-based) so a reset of the
        // navigationPath, e.g. tapping a media tab, pops the detail cleanly
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
                // Layout-shift: a UNIFORM text block. Title reserves both
                // lines, author/status lines always exist (empty when absent),
                // so every cell in a LazyVGrid row is equally tall and rows
                // stop jumping while scrolling (variable-height stutter,
                // Apple Forums 685461).
                Text(entry.item.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                Text(entry.item.author ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1, reservesSpace: true)
                // The time line is ALWAYS filled. Remaining when
                // started, total runtime otherwise (evenly dense grid, no
                // grow-in jank: only the text changes, never the height).
                Text(bookTimeLine(progress: entry.progress, duration: entry.item.media?.duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1, reservesSpace: true)
            }
            .frame(width: width, alignment: .leading)
            // Top-align within the grid row: LazyVGrid sizes each row to its
            // tallest cell and CENTERS shorter ones. Covers of cells with
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
            DownloadInstallRing(itemId: entry.id, tileWidth: width)
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

/// Cover grid of a group. Measures its own width and uses the same column math
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
            CoverGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
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

/// Downloaded-audiobook row. Mirrors the podcast episode row (same
/// `MediaRowContent` layout + a large play button, tap opens the detail page)
/// so the audiobook "Downloaded" section reads and behaves like the podcast
/// pendant.
struct BookDownloadRow: View {
    let entry: LibraryEntry
    @ObservedObject var playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

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
                    // TF4/E1: the Downloaded section is rebuilt by its parent
                    // (LibraryView) when downloads change, so this row reads the
                    // flag non-observed. It never re-renders on a progress tick.
                    downloadedBadge: DownloadManager.shared.isDownloaded(itemId: entry.id),
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


/// The ONE audiobook stock grid. Flat or series-grouped (follows
/// `viewModel.sortOption`), shared between the tab's 9-tile PREVIEW
/// (`limit: 9`) and the full `AllBooksPage` (`limit: nil` = staged paging over
/// the whole stock, the former in-tab behaviour moved here unchanged). Cells
/// are the shared `BookGridCell`/`SeriesStackCell`; a series stack pushes the
/// shared `BrowseBooksScreen` as its volume list.
struct AudiobookStockGrid: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// nil = the endless form. A number caps the grid (preview. No paging).
    var limit: Int? = nil

    @State private var measuredWidth: CGFloat = 0
    @State private var visibleCount = AudiobookStockGrid.pageSize
    static let pageSize = 60
    /// The preview showed too little to read as a stock. 24
    /// now, and everything beyond it lives on the full page (the "show all"
    /// line below the grid navigates there). Adaptive columns keep iPad rows
    /// full.
    static let previewLimit = 24

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

    /// Display window: the preview cap, or the staged-paging window.
    private var window: Int { limit ?? visibleCount }

    var body: some View {
        Group {
            if viewModel.sortOption == .serie {
                seriesGrid
            } else {
                flatGrid
            }
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
        // Sort/search changes reset the paging window (a fresh order starts at
        // the top anyway; keeps early pages small after narrowing).
        .onChange(of: viewModel.sortOption) { _, _ in visibleCount = Self.pageSize }
        .onChange(of: viewModel.sortAscending) { _, _ in visibleCount = Self.pageSize }
        .onChange(of: viewModel.filterOption) { _, _ in visibleCount = Self.pageSize }
    }

    private var flatGrid: some View {
        let all = viewModel.sortedFilteredEntries
        let columns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(Array(all.prefix(window))) { entry in
                BookGridCell(
                    entry: entry,
                    width: cellWidth,
                    playerCoordinator: playerCoordinator,
                    libraryViewModel: viewModel
                )
            }
            if limit == nil, window < all.count {
                Color.clear.frame(height: 1)
                    .onAppear { visibleCount += Self.pageSize }
            }
        }
        .padding(.horizontal)
    }

    /// Grid under series sorting: series as stacks, single books normal.
    private var seriesGrid: some View {
        let grouped = viewModel.seriesGroupedEntries
        let shown = Array(grouped.prefix(window))
        let columns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(shown) { gridEntry in
                switch gridEntry {
                case .single(let entry):
                    // Same top spacing as the fan headroom of the stack tiles.
                    // Otherwise covers/texts in mixed rows sit at different heights.
                    BookGridCell(
                        entry: entry,
                        width: cellWidth,
                        playerCoordinator: playerCoordinator,
                        libraryViewModel: viewModel
                    )
                    .padding(.top, 10)
                case .series(let name, let entries):
                    NavigationLink {
                        // The volume list is the shared title+grid screen.
                        // Same cells, same behaviour as every browse surface.
                        BrowseBooksScreen(
                            title: name,
                            entries: entries,
                            playerCoordinator: playerCoordinator,
                            libraryViewModel: viewModel
                        )
                    } label: {
                        SeriesStackCell(
                            name: name,
                            entries: entries,
                            cellWidth: cellWidth,
                            coverURL: { AppSession.shared.coverURL(forItemId: $0) }
                        )
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .buttonStyle(.plain)
                }
            }
            if limit == nil, window < grouped.count {
                Color.clear.frame(height: 1)
                    .onAppear { visibleCount += Self.pageSize }
            }
        }
        .padding(.horizontal)
    }

    /// Pure (J1 count rule): how many BOOKS the preview window shows. A
    /// series stack counts its members, so the heading's counted chevron
    /// compares books to books.
    nonisolated static func previewBookCount(_ entries: [LibraryViewModel.GridEntry],
                                             limit: Int) -> Int {
        entries.prefix(limit).reduce(0) {
            switch $1 {
            case .single: $0 + 1
            case .series(_, let members): $0 + members.count
            }
        }
    }
}

/// The full stock behind the "All Books" preview. The endless
/// grid (staged paging, series grouping) that used to live ON the tab, plus
/// the sort/filter control, which moved here with it. The control sits on
/// the surface it acts on.
struct AllBooksPage: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var playerCoordinator: PlayerCoordinator

    /// Only what DEVIATES from the default is named (pure `SortIndicator`).
    private var sortLabel: String? {
        SortIndicator.summary([
            SortIndicator.part(viewModel.sortOption.label,
                               ifNot: viewModel.sortOption == .titel
                                   && viewModel.sortAscending == SortOption.titel.defaultAscending),
            SortIndicator.part(viewModel.filterOption.label,
                               ifNot: viewModel.filterOption == .alle),
        ])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer(minLength: 12)
                    SectionSortControl(activeLabel: sortLabel) { sortMenu }
                        .padding(.horizontal)
                }
                AudiobookStockGrid(viewModel: viewModel,
                                   playerCoordinator: playerCoordinator)
            }
            .padding(.top, 12)
            .bottomBarClearance()
        }
        .navigationTitle(Text(verbatim: FilteredHead.title(
            String(localized: "All Books"),
            filterLabel: SortIndicator.part(viewModel.filterOption.label,
                                            ifNot: viewModel.filterOption == .alle))))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Audiobooks. The reference menu, unchanged (LibraryViewModel state);
    /// moved from the tab section with the control.
    @ViewBuilder private var sortMenu: some View {
        Picker("Sort By", selection: $viewModel.sortOption) {
            ForEach(SortOption.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        Button {
            viewModel.sortAscending.toggle()
        } label: {
            Label(
                viewModel.sortAscending ? String(localized: "Ascending") : String(localized: "Descending"),
                systemImage: viewModel.sortAscending ? "arrow.up" : "arrow.down"
            )
        }
        Divider()
        Picker("Filter", selection: $viewModel.filterOption) {
            ForEach(FilterOption.allCases) { option in
                Text(option.label).tag(option)
            }
        }
    }
}
