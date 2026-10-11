// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Shared building blocks for book grids: cell, Haptic Touch menu and the
/// author/genre browsing screens. Extracted from `LibraryView` so the browse
/// grids get exactly the same look and the same menu.

/// Status line below the cover ("Finished" / "x h left" / "x % listened").
/// Pure, like its sister `bookTimeLine`.
nonisolated func bookStatusText(_ p: BookProgress, duration: Double?) -> String {
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
    return DurationText.length(seconds: duration)
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
    /// Hands up the sentence of a refused mark. The menu is closed when the
    /// answer comes, so the cell that hosts it says it.
    var onRefused: (String) -> Void = { _ in }

    /// Offline, playing needs a download and starting a download is
    /// impossible. Gate the menu entries consistently with the detail page.
    @Environment(\.isOnline) private var isOnline
    /// Routes a title to ITS source by id. The menu acts on the entry under
    /// the finger, which is not necessarily the one that plays.
    @Environment(\.itemRouter) private var router
    private var isOffline: Bool { !isOnline }
    /// Whether the title plays offline, so the menu observes the stock
    /// itself; the download entries observe their own state below. It is
    /// attached to every book cell, and no page that shows those cells has
    /// to observe for the menu to be current.
    private let downloadManager = DownloadManager.shared
    @ObservedObject private var downloadStock = DownloadManager.stock

    init(entry: LibraryEntry, playerCoordinator: PlayerCoordinator, libraryViewModel: LibraryViewModel,
         showsContinueHide: Bool = false, onRefused: @escaping (String) -> Void = { _ in }) {
        self.entry = entry
        self.playerCoordinator = playerCoordinator
        self.libraryViewModel = libraryViewModel
        self.showsContinueHide = showsContinueHide
        self.onRefused = onRefused
    }

    var body: some View {
        // Play only when it can actually start (online, or downloaded).
        if MediaAvailability.canPlayNow(
            isConnected: !isOffline,
            isDownloaded: downloadManager.isDownloaded(itemId: entry.id)) {
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

        BookDownloadMenuItems(itemId: entry.id)

        Button {
            Task { await quickToggleFinished() }
        } label: {
            let gesture = entry.progress?.markGesture ?? .markPlayed
            Label(
                gesture.marksPlayed ? String(localized: "Mark as Finished") : String(localized: "Mark as Unfinished"),
                systemImage: gesture.marksPlayed ? "checkmark.circle" : "checkmark.circle.fill"
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

    /// The same door as the detail page (`BookFinishMark`), so a catalogue
    /// title's mark lands on the device here too, and a refused mark says
    /// the detail page's sentence.
    private func quickToggleFinished() async {
        // The provider OF THIS TITLE, not the main one: the coordinator's
        // provider is fixed at construction and is the MAIN library provider
        // (a `let` from its `init`), never what plays, and a title
        // carries its source in its id (a Jellyfin book asked the library
        // server and its position was written nowhere).
        // The same rule as the label: the flag alone missed a book whose
        // numbers say complete, and marked it finished a second time.
        let outcome = await BookFinishMark.apply(entry, target: (entry.progress?.markGesture ?? .markPlayed).marksPlayed,
                                                 progress: entry.progress, provider: router.provider(entry.id),
                                                 coordinator: playerCoordinator, libraryViewModel: libraryViewModel)
        if let reason = outcome.reason { onRefused(reason) }
    }
}

/// Lifted force-press preview on our adaptive glass instead of the plain
/// system platter, so it matches the rest of the chrome. Deliberately
/// NEUTRAL glass: the shared accent belongs to the PLAYING book, not the
/// pressed one.
struct BookContextPreview: View {
    @Environment(\.itemRouter) private var router
    let entry: LibraryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BookCoverView(
                url: router.coverURL(entry.id),
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
    /// The sentence of a mark the menu asked for and the server refused,
    /// the same the detail page shows in its line.
    @State private var refusal: String?

    init(entry: LibraryEntry, playerCoordinator: PlayerCoordinator, libraryViewModel: LibraryViewModel,
         showsContinueHide: Bool = false) {
        self.entry = entry
        self.playerCoordinator = playerCoordinator
        self.libraryViewModel = libraryViewModel
        self.showsContinueHide = showsContinueHide
    }

    func body(content: Content) -> some View {
        content.contextMenu {
            BookContextMenuItems(
                entry: entry,
                playerCoordinator: playerCoordinator,
                libraryViewModel: libraryViewModel,
                showsContinueHide: showsContinueHide,
                onRefused: { refusal = $0 }
            )
        } preview: {
            BookContextPreview(entry: entry)
        }
        .sentenceAlert($refusal)
    }
}

// MARK: - Grid cell

/// A book cell (cover + title + author + status) incl. navigation to the detail
/// page and Haptic Touch menu. Identical in library and browse.
struct BookGridCell: View {
    @Environment(\.itemRouter) private var router
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
                    url: router.coverURL(entry.id),
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
    @Environment(\.itemRouter) private var router
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
                    coverURL: router.coverURL(entry.id),
                    eyebrow: entry.item.author,
                    title: entry.item.title,
                    // The Downloaded section is rebuilt by its parent
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
    @Environment(\.itemRouter) private var router
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
                            coverURL: { router.coverURL($0) }
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

    /// Pure count rule: how many BOOKS the preview window shows. A
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

/// The download entries of a book's long-press menu: delete when stored,
/// pause, resume or cancel while it loads, and the offer where the source
/// can download and the device is online. One piece for the book cells'
/// menu and the cover of the book page, so both say the same.
struct BookDownloadMenuItems: View {
    let itemId: String
    @Environment(\.isOnline) private var isOnline
    @Environment(\.itemRouter) private var router
    private let downloadManager = DownloadManager.shared
    @ObservedObject private var downloadStock = DownloadManager.stock
    @ObservedObject private var downloadProgress: ItemDownloadProgress

    init(itemId: String) {
        self.itemId = itemId
        _downloadProgress = ObservedObject(wrappedValue: DownloadManager.progress.item(itemId))
    }

    var body: some View {
        if downloadManager.isDeletableDownload(itemId: itemId) {
            Button(role: .destructive) {
                downloadManager.deleteDownload(itemId: itemId)
            } label: {
                Label("Delete Download", systemImage: "trash")
            }
        } else {
            // Mirror the detail page's download controls: a running or
            // paused download used to leave the menu without ANY download
            // entry. Pause/resume/cancel work from the library too.
            switch downloadManager.phase[itemId] {
            case .downloading:
                Button {
                    downloadManager.pauseDownload(itemId: itemId)
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
                Button(role: .destructive) {
                    downloadManager.cancelDownload(itemId: itemId)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            case .paused:
                Button {
                    downloadManager.resumeDownload(itemId: itemId)
                } label: {
                    Label("Resume", systemImage: "play.circle")
                }
                Button(role: .destructive) {
                    downloadManager.cancelDownload(itemId: itemId)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            case .failed, nil:
                // Only a source that CAN download gets the offer. An imported
                // local file is already on the device and has no download
                // capability; before this check it was offered „Save for
                // Offline" and would have fetched its detail from the library
                // provider, which does not know it.
                if isOnline, MediaDownloadOffer.isPossible(router.provider(itemId).capabilities) {
                    Button {
                        // The quick variant, without a Wi-Fi prompt.
                        Task { await downloadManager.startDownload(itemId: itemId, kind: .audiobooks) }
                    } label: {
                        Label("Save for Offline", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
    }
}
