// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog
import UIKit

/// Detail page of a book: cover, title, author, description and a play button
/// that starts playback in the coordinator and navigates to the full player.
/// Shown when tapping a book in the library.
///
/// Three layouts depending on available space:
/// - iPhone portrait: large cover across the full width with fade-out
/// - iPhone landscape and iPad: cover on the left, title/info/buttons to the
///   right (the extra width used sensibly instead of just scaling down)
struct BookDetailScreen: View {
    @Environment(\.itemRouter) private var router
    let entry: LibraryEntry
    @ObservedObject var coordinator: PlayerCoordinator
    /// Absent on the catalog entry path: a catalog title has no library
    /// list to refresh and no sibling entries. Every use is guarded, and
    /// the SERVER path keeps passing it exactly as before.
    var libraryViewModel: LibraryViewModel?
    /// Held, not observed: the page only CALLS the manager (start a download,
    /// read once for the diagnosis report). What shows the download state is
    /// `BookDownloadCapsule`, so a progress publish re-runs that capsule and
    /// not this page with its chapter list.
    private let downloadManager = DownloadManager.shared

    /// The same move that unified the show page, one page up: the server
    /// page is the FORM, and a catalog title enters through a second door
    /// instead of getting a smaller page of its own. The id decides per render what differs
    /// (progress home, provider, secondary buttons); the page is the same.
    init(entry: LibraryEntry, coordinator: PlayerCoordinator,
         libraryViewModel: LibraryViewModel) {
        self.entry = entry
        self.coordinator = coordinator
        self.libraryViewModel = libraryViewModel
    }

    init(catalogItem: LibraryItem, coordinator: PlayerCoordinator) {
        self.entry = LibraryEntry(item: catalogItem, progress: nil)
        self.coordinator = coordinator
        self.libraryViewModel = nil
    }

    /// Resolved from the ID per render, never stored: the same rule that
    /// kept the subscribed show page honest during a cold start.
    private var isCatalogTitle: Bool { FreeCatalog.isCatalogId(entry.id) }

    /// The provider that answers for THIS title, resolved from its id.
    ///
    /// It used to route only a catalog title and hand everything else to the
    /// coordinator's provider. That one is fixed at construction and is the
    /// MAIN library provider, not whatever plays: `PlayerCoordinator.provider`
    /// is a `let` from its `init`, and `AppSession` builds it with the main
    /// one. So the answer was the same wrong answer every time, which is the
    /// wrong question for a BROWSED title whose id names its source: a
    /// Jellyfin book asked the library server, which has never heard of it,
    /// so the page stayed without tracks and the player without chapters.
    /// The router answers with the main provider for an id that carries no
    /// namespace, so the server path is unchanged.
    private var detailProvider: any AudioProvider { router.provider(entry.id) }

    @State private var detail: LibraryItemDetail?
    /// The item the page names (`BookPageItem`): the entry's, else the
    /// loaded detail's when the entry carries no title.
    private var shownItem: LibraryItem { BookPageItem.shown(entry: entry.item, detail: detail) }
    @State private var isLoading = true
    /// The detail could not be fetched: the page says so and offers the
    /// retry, instead of an empty description and a silent download button.
    @State private var detailFailed = false
    @State private var showWiFiWarning = false
    @State private var copiedReport = false
    @State private var isFinishedOverride: Bool?
    @State private var errorMessage: String?
    @StateObject private var colorLoader = CoverColorLoader()
    /// Label column scales with Dynamic Type. 90pt fixed broke
    /// "Erzähler/Erschienen" mid-word at AX sizes.
    @ScaledMetric(relativeTo: .caption) private var infoLabelWidth: CGFloat = 90
    /// What the two buttons under the main one take side by side, at the
    /// current type size (`DetailButtonRow`).
    @ScaledMetric(relativeTo: .body) private var buttonPairWidth: CGFloat = DetailButtonRow.sideBySideMinWidth
    /// The same in their compact form.
    @ScaledMetric(relativeTo: .body) private var compactPairWidth: CGFloat = DetailButtonRow.compactMinWidth

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.isOnline) private var isOnline
    @Environment(\.bottomBarInset) private var bottomBarInset
    /// The bottoms of the cover and of the button row under the main button
    /// in the page's own space: their distance is what stands under the cover
    /// down to the last button, the same at every cover size, so at rest no
    /// button lies under the playback bar (`DetailCoverSide`).
    @State private var coverBottom: CGFloat = 0
    @State private var blockBottom: CGFloat = 0
    /// Their distance as the cover is sized by it, settled to whole points
    /// (`DetailCoverSide.settled`), so the page comes to rest.
    @State private var belowCover: CGFloat = 0
    /// The page stands on top of its stack (appeared, nothing pushed over it).
    @State private var isTopPage = false
    private func noteBelowCover() {
        belowCover = DetailCoverSide.settled(belowCover, measured: max(0, blockBottom - coverBottom))
    }
    private static let pageSpace = "bookDetailPage"

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }


    /// The cover's long press downloads or deletes the book, with the same
    /// entries as the book cells' menu. The labelled capsule below stays;
    /// the long press is the way every detail page shares.
    @ViewBuilder
    private var coverDownloadMenu: some View {
        if !isCatalogTitle {
            BookDownloadMenuItems(itemId: entry.id)
        }
    }

    /// The cover across the page's own width, edge to edge: the width the
    /// window gives this page, not the screen's, so a split window and an
    /// unfolded iPhone Duo get a cover that fits. Smaller than that width it
    /// stands as a card (`DetailCoverCard`).
    private func heroCover(side: CGFloat, card: Bool) -> some View {
        coverImageContent
            .frame(width: side, height: side)
            .clipped()
            .contextMenu { coverDownloadMenu }
            // Progress bar sitting ON the cover's bottom edge, edge to edge.
            .overlay(alignment: .bottom) {
                if let p = currentProgress, p.isStarted, !isFinished {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.black.opacity(0.35))
                            Rectangle()
                                .fill(AppTheme.accent)
                                .frame(width: geo.size.width * p.fraction)
                        }
                    }
                    .frame(height: 4)
                }
            }
            .coverCard(card)
            // The author portrait floats on the SEAM between cover and
            // gradient (avatar-over-banner pattern), trailing side. Mostly
            // above the edge, dipping slightly below it.
            .overlay(alignment: .bottomTrailing) {
                authorPortrait
                    .padding(.trailing, 20)
                    .offset(y: Self.portraitSize / 2 - 16)
            }
            .frame(maxWidth: .infinity)
    }

    /// LibriVox hi-res cover once resolved (thumb first, soft upgrade):
    /// the affordance the old catalog sheet carried, kept on the page.
    @State private var hiresCover: URL?

    private var coverImageContent: some View {
        CachedAsyncImage(url: hiresCover ?? router.coverURL(entry.id)) { image, pixels in
            // A large cover stands alone on its page, so it can afford
            // the blurred enlargement behind a fitted picture.
            CoverFitting(image: image, pixelSize: pixels, backdrop: .blurredSelf)
        } placeholder: {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary))
        }
        .animation(.easeInOut(duration: 0.25), value: hiresCover)
        .task {
            if entry.id.hasPrefix(FreeCatalog.librivoxPrefix) {
                hiresCover = await LibriVoxCoverLoader.hiresCover(forItemId: entry.id)
            }
        }
    }

    /// Title/author/progress. Centered and white for the hero view (it sits on
    /// the colored gradient background, where `.primary` is not enough, that
    /// would be black and unreadable in light system mode), left-aligned with
    /// normal adaptive colors for the side-by-side layout (there the background
    /// is the normal system background).
    private func titleBlock(alignment: HorizontalAlignment) -> some View {
        let isHero = alignment == .center
        return VStack(alignment: alignment, spacing: 6) {
            Text(shownItem.title)
                .font(.title2).bold()
                .multilineTextAlignment(isHero ? .center : .leading)
                .foregroundStyle(isHero ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            if let author = shownItem.author {
                // Round author portrait next to the author line. ONLY when
                // the server ships an image (no placeholder, no initials; the
                // row looks like before otherwise, same rule as music artists
                // without a picture). Tapping filters the library to this
                // author (the image is function, not decoration) and is only
                // active when the author has MORE than one work here.
                // In the hero the portrait FLOATS on the cover edge (see
                // heroCover overlay). The author line stays pure text. The
                // left-aligned side-by-side layout keeps the inline row.
                if isHero {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(AnyShapeStyle(.white.opacity(0.75)))
                } else {
                    HStack(spacing: 12) {
                        authorPortrait
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(AnyShapeStyle(.secondary))
                    }
                }
            }
            if let p = currentProgress, p.isStarted, !isFinished {
                Text(p.remainingText(bookDuration: entry.item.media?.duration) ?? String(localized: "\(p.fraction.formatted(.percent.precision(.fractionLength(0)))) listened"))
                    .font(.caption)
                    .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.secondary))
            } else if isFinished {
                Text("Completed")
                    .font(.caption)
                    .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.secondary))
            }
        }
    }

    /// Portrait URL. Only for ABS books whose expanded payload carries an
    /// author id; the request itself only renders when the image loads.
    private var authorImageURL: URL? {
        guard let authorId = detail?.media.metadata?.authors?.first?.id else { return nil }
        return (detailProvider as? APIClient)?.authorImageURL(authorId: authorId)
    }

    /// The author's works in the library. The tap filter is only active
    /// for more than one work (pure rule, tested).
    private var authorWorks: [LibraryEntry] {
        guard let author = shownItem.author else { return [] }
        return (libraryViewModel?.entries ?? []).filter { $0.item.author == author }
    }

    /// Portrait diameter. Floats on the cover/gradient seam.
    private static let portraitSize: CGFloat = 72

    @ViewBuilder
    private var authorPortrait: some View {
        if let url = authorImageURL {
            let works = authorWorks
            // Frame INSIDE the success branch: while loading (and when the
            // server has no image) nothing renders and nothing reserves space.
            // The row looks exactly like today.
            let portrait = CachedAsyncImage(url: url, useThumbnail: true) { image in
                // A clean round portrait in the established form language.
                // The show-cover corner badge's look (crisp image + thin white
                // rim), only ROUND. No smear, no dissolve, no grayscale.
                image.resizable().aspectRatio(contentMode: .fill)
                    .frame(width: Self.portraitSize, height: Self.portraitSize)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
            } placeholder: {
                // An `EmptyView` placeholder never "appears",
                // so CachedAsyncImage's `.task(id:)` never fired and the load
                // never STARTED. Server 200s notwithstanding. A zero-sized
                // real view participates in the lifecycle while still
                // reserving no visible space without an image.
                Color.clear.frame(width: 0, height: 0)
            }
            if let libraryViewModel,
               LibraryViewModel.authorFilterEnabled(workCount: works.count),
               let author = shownItem.author {
                NavigationLink {
                    BrowseBooksScreen(title: author, entries: works,
                                      playerCoordinator: coordinator,
                                      libraryViewModel: libraryViewModel)
                } label: { portrait }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("All books by \(author)"))
            } else {
                portrait
            }
        }
    }

    /// Side-by-side layout (landscape): cover column pinned to the edges on
    /// the left, scrollable info column on the right. A short page fills the
    /// full height with the SHARP cover; a tall one would need a far larger
    /// source, so a heavily BLURRED ambient panel (blur hides any resolution)
    /// carries the height with the sharp cover floating on top
    /// (`BookDetailCover`, by the page's height, not the device).
    private var sideBySideLayoutView: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if BookDetailCover.sharpFills(height: geo.size.height) {
                    coverImageContent
                        .frame(width: geo.size.height, height: geo.size.height)
                        .clipped()
                        .contextMenu { coverDownloadMenu }
                } else {
                    ZStack {
                        coverImageContent
                            .frame(width: 420, height: geo.size.height)
                            .clipped()
                            .blur(radius: 45)
                            .overlay(Color.black.opacity(systemColorScheme == .dark ? 0.3 : 0.1))
                        BookCoverView(
                            url: router.coverURL(entry.id),
                            progress: currentProgress,
                            itemId: entry.id,
                            size: 320
                        )
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                        .contextMenu { coverDownloadMenu }
                    }
                    .frame(width: 420, height: geo.size.height)
                    .clipped()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 14) {
                            titleBlock(alignment: .leading)
                            infoSection(withPadding: false)
                            playArea(withPadding: false)
                            buttonRow(width: geo.size.width - 420 - 48)
                        }
                        trailingSections(isHero: false)
                    }
                    // Room for the back button at the top, mini-player at the bottom.
                    .padding(.top, 60)
                    .padding(.bottom, 20)
                    .bottomBarClearance()
                    .padding(.horizontal, 24)
                }
                .scrollContentBackground(.hidden)
                .reportsBottomBarScroll()
            }
        }
        // Cover column all the way to the screen edges.
        .ignoresSafeArea()
    }

    /// A wide window (the open iPhone Duo, an iPad in landscape): cover and
    /// facts in the left column, the chapters as their own list in the
    /// right one. Each column scrolls on its own.
    private var twoColumnLayoutView: some View {
        FoldColumns { column in
            let content = column.width - 24 - FoldSplit.pageGutter
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // In its half and as large as leaves title and play
                    // above the playback bar (`DetailCoverSide`).
                    BookCoverView(
                        url: router.coverURL(entry.id),
                        progress: currentProgress,
                        itemId: entry.id,
                        size: DetailCoverSide.side(columnWidth: content, height: column.height, top: 60,
                                                   below: belowCover, bottomReserve: bottomBarInset)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .contextMenu { coverDownloadMenu }
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.pageSpace)).maxY } action: {
                        coverBottom = $0
                        noteBelowCover()
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        titleBlock(alignment: .leading)
                        infoSection(withPadding: false)
                        playArea(withPadding: false)
                        buttonRow(width: content)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.pageSpace)).maxY } action: {
                                blockBottom = $0
                                noteBelowCover()
                            }
                    }
                    trailingSections(isHero: false, showsChapterLink: false)
                }
                .coordinateSpace(.named(Self.pageSpace))
                .padding(.top, 60)
                .padding(.bottom, 20)
                .bottomBarClearance()
                // At the fold the gutter the frame counts on (`FoldColumns`).
                .padding(.leading, 24)
                .padding(.trailing, FoldSplit.pageGutter)
            }
            .scrollContentBackground(.hidden)
            .reportsBottomBarScroll()
        } trailing: { _ in
            chapterColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// The download and mark buttons: side by side where both fit whole,
    /// else side by side with glyph and short word, else one under the
    /// other (`DetailButtonRow`).
    private func buttonRow(width: CGFloat) -> some View {
        let form = DetailButtonRow.form(width: width, needs: buttonPairWidth, compactNeeds: compactPairWidth)
        let layout = form == .stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            downloadSection(compact: form == .compact)
            markAsFinishedButton(compact: form == .compact)
        }
    }

    /// The right column of the wide page: the chapter list itself, not a
    /// link to it.
    @ViewBuilder
    private var chapterColumn: some View {
        if let resolved = resolvedChapters, !resolved.chapters.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(ChapterModel.selectorLabel(isMusic: false, isFallback: resolved.isFallback))
                    .font(.headline)
                    .padding(.leading, FoldSplit.pageGutter)
                    .padding(.trailing, 20)
                    .padding(.top, 60)
                    .padding(.bottom, 8)
                DetailChapterList(bookTitle: shownItem.title, chapters: resolved.chapters,
                                  coordinator: coordinator, entry: entry, embedded: true)
            }
        } else if isLoading {
            ProgressView().padding(.top, 80)
        }
    }

    /// The SAME validated/resolved chapter list the player uses, never the
    /// raw server chapters. Otherwise a coverage-fallback book shows a
    /// different (broken) chapter list here than in the player.
    private var resolvedChapters: (chapters: [ABSChapter], isFallback: Bool)? {
        guard let media = detail?.media else { return nil }
        let resolved = ChapterModel.resolved(
            chapters: media.chapters ?? [], tracks: media.tracks ?? [],
            duration: media.duration ?? 0)
        return (resolved.chapters, resolved.isFallback)
    }

    /// Chapter link, error text and description. Shared between the portrait and
    /// landscape layouts; the wide page shows the chapters in their own column.
    @ViewBuilder
    private func trailingSections(isHero: Bool, showsChapterLink: Bool = true) -> some View {
        if showsChapterLink, let resolved = resolvedChapters, !resolved.chapters.isEmpty {
            chapterLink(resolved.chapters, isFallback: resolved.isFallback, isHero: isHero)
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal)
        }

        if let description = detail?.media.metadata?.description, !description.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                    .font(.headline)
                Text(Self.plainText(fromHTML: description))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        } else if isLoading {
            ProgressView().padding()
        } else if detailFailed {
            LoadFailedView(form: .line) { Task { await loadDetail() } }
                .padding(.horizontal)
        }

        // The catalog title's rights and takeover, exactly what the old
        // sheet carried: the licence capsule (or the computed note), the
        // source backlink, and for LibriVox books the take-into-library
        // menu. Server titles never show these.
        if isCatalogTitle {
            CatalogRightsSection(item: entry.item)
                .padding(.horizontal)
            if entry.id.hasPrefix(FreeCatalog.librivoxPrefix) {
                LibriVoxTakeoverSection(item: entry.item)
                    .padding(.horizontal)
            }
        }

        // How close to the end this book counts as finished (credits).
        PlayedTailBookRow(itemId: entry.id)
            .padding(.horizontal)

        // The book's progress diagnosis. The same instrument the
        // podcast sheet carries, in its book view. It exists because a
        // a position jumping backwards could not be PROVEN: it puts server
        // state, local second backup and the cached detail side by side, each
        // with its
        // timestamp, and names the start the app would pick right now.
        // Only in builds from Xcode, never in a release build.
        #if DEBUG
        diagnosisSection
        #endif
    }

    @ViewBuilder
    private var diagnosisSection: some View {
        // Diagnostic UI stays verbatim (project convention).
        VStack(alignment: .leading, spacing: 6) {
            Button {
                UIPasteboard.general.string = progressReport()
                copiedReport = true
            } label: {
                Label {
                    Text(verbatim: "Fortschritts-Diagnose kopieren")
                } icon: {
                    Image(systemName: "doc.on.clipboard")
                }
                .font(.footnote)
            }
            .accessibilityIdentifier("book-progress-diagnosis-copy")
            if copiedReport {
                Text(verbatim: "In die Zwischenablage gelegt.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    /// Read-only: where this book's position could come from, and which one
    /// the start would take.
    private func progressReport() -> String {
        let saved = ListeningStore.backup(entry.id)
        let cached = downloadManager.loadCachedDetail(forItemId: entry.id)
        let flushed = ListeningStore.flushed(entry.id)
        let sources = ProgressDiagnosis.BookSources(
            serverPosition: entry.progress?.currentTime,
            serverUpdatedAtMs: entry.progress?.lastUpdate,
            localPosition: (saved?.count ?? 0) >= 2 ? saved?[0] : nil,
            localSavedAtMs: (saved?.count ?? 0) >= 2 ? saved?[1] : nil,
            cachedPosition: cached?.userMediaProgress?.currentTime,
            cachedUpdatedAtMs: cached?.userMediaProgress?.lastUpdate,
            flushedPosition: (flushed?.count ?? 0) >= 2 ? flushed?[0] : nil,
            flushedAtMs: (flushed?.count ?? 0) >= 2 ? flushed?[1] : nil,
            serverIsFinished: entry.progress?.isFinished,
            progressFraction: entry.progress?.fraction,
            jumpRing: JumpRingRows.matching(AppStorageKeys.store).entry(CarrierRowsSpec.entryOwner, entry.id) ?? [],
            duration: detail?.media.duration ?? entry.item.media?.duration ?? 0,
            isDownloaded: downloadManager.isDownloaded(itemId: entry.id),
            // There is no separate progress QUEUE (positions push directly);
            // what exists is the bookmark queue and the sync history. The
            // honest stand-in for "what does this device still owe".
            pendingSyncOperations: BookmarkQueue.shared.pendingOps()
                .filter { $0.itemId == entry.id }.count)
        return ProgressDiagnosis.bookReport(
            title: shownItem.title,
            sources: sources,
            now: Date().timeIntervalSince1970,
            format: { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .standard) },
            formatTime: { seconds in
                let total = Int(seconds.rounded())
                return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            })
    }

    var body: some View {
        // Side-by-side only in LANDSCAPE (iPhone via compact height, iPad via
        // geometry. Its size classes don't change on rotation). Portrait
        // always uses the single-column hero layout, on iPad too.
        GeometryReader { geo in
        let layout = BookDetailLayout.of(width: geo.size.width, height: geo.size.height,
                                         compactHeight: verticalSizeClass == .compact)
        let useSideBySideLayout = layout != .hero
        ZStack {
            if !useSideBySideLayout {
                // Gradient as the BACKGROUND for the whole upper area, like the
                // large player. Cover and title sit freely on top.
                // No more black at the very top (starts directly with the cover
                // color), fades softly to black just below the buttons and stays
                // black after that.
                LinearGradient(
                    stops: [
                        .init(color: colorLoader.topAccent, location: 0.00),
                        .init(color: colorLoader.topAccent.opacity(0.85), location: 0.45),
                        .init(color: .black.opacity(0.75), location: 0.85)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            } else {
                // Carry the cover color theme into the side-by-side layout.
                // Fading into the SYSTEM tone: black in dark mode, white in
                // light mode (adaptive text stays readable on the pastel top).
                LinearGradient(
                    stops: [
                        .init(color: colorLoader.topAccent.opacity(systemColorScheme == .dark ? 0.7 : 0.45), location: 0.0),
                        .init(color: systemColorScheme == .dark ? .black : .white, location: 0.55)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }

            if layout == .twoColumns {
                twoColumnLayoutView
            } else if useSideBySideLayout {
                sideBySideLayoutView
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        VStack(spacing: 8) {
                            // The full width where the window is tall enough,
                            // else as large as leaves title and play above the
                            // playback bar, as a card (`DetailCoverCard`).
                            let coverForm = DetailCoverCard.form(
                                width: geo.size.width,
                                height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom,
                                safeTop: geo.safeAreaInsets.top, below: belowCover,
                                bottomReserve: bottomBarInset + geo.safeAreaInsets.bottom)
                            heroCover(side: coverForm.side, card: coverForm.isCard)
                                .padding(.top, coverForm.top)
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.pageSpace)).maxY } action: {
                                    coverBottom = $0
                                    noteBelowCover()
                                }
                            titleBlock(alignment: .center)
                                .padding(.horizontal)
                        }
                        infoSection(withPadding: true)
                        playArea(withPadding: true)
                        buttonRow(width: min(geo.size.width, 600) - 32)
                            .padding(.horizontal)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.pageSpace)).maxY } action: {
                                blockBottom = $0
                                noteBelowCover()
                            }

                        trailingSections(isHero: true)
                    }
                    .coordinateSpace(.named(Self.pageSpace))
                    // Free space at the page end: mini-player + search button
                    // otherwise cover the last lines.
                    .padding(.bottom, 20)
                    .bottomBarClearance()
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                }
                // Without this the ScrollView itself has an opaque default fill
                // that sits over the gradient in the background.
                .scrollContentBackground(.hidden)
                .reportsBottomBarScroll()
                // Must sit on the ScrollView itself (a child cannot break through
                // the safe area).
                .ignoresSafeArea(edges: .top)
                // Portrait/hero layout is ALWAYS dark (cover gradient):
                // pin the scheme so .primary text and glass stay light-on-dark.
                .environment(\.colorScheme, .dark)
                // The side column beside it turns dark as well, while this
                // page is the top one: a page pushed over it (the chapters)
                // stands light, and its own brightness reaches the column.
                .sideColumnScheme(isTopPage ? .dark : nil)
                .onAppear { isTopPage = true }
                .onDisappear { isTopPage = false }
            }
        }
        // The kept height below the cover only grows; a new window starts
        // it again (`DetailCoverSide.settled`).
        .onChange(of: geo.size) { _, _ in belowCover = 0 }
        } // GeometryReader
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .alert("No Wi-Fi Detected", isPresented: $showWiFiWarning) {
            Button("Download Anyway") {
                Task { await reallyStartDownload() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You're not on Wi-Fi. This download may use cellular data.")
        }
        .task { await loadDetail() }
        .task(id: entry.id) {
            await colorLoader.load(from: router.coverURL(entry.id))
        }
    }

    // MARK: - Play/Pause

    /// Play button + optional "Start from beginning" link below it.
    @ViewBuilder
    private func playArea(withPadding: Bool) -> some View {
        VStack(spacing: 8) {
            playButton(withPadding: withPadding)
            if currentProgress?.isStarted == true || isFinished {
                Button("Start from Beginning") {
                    Task { await restartFromBeginning() }
                }
                .font(.footnote)
                .foregroundStyle(withPadding ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
            }
        }
    }

    /// The detail of the book (description, chapters, the download's
    /// tracks). A failure has its line and turns the page's empty
    /// description into the retry; a cancellation is no failure.
    private func loadDetail() async {
        isLoading = true
        detailFailed = false
        do {
            detail = try await detailProvider.fetchItemDetail(itemId: entry.id)
        } catch {
            if !error.isCancellation {
                detailFailed = true
                Logger.library.notice("BOOK detail failed item=\(entry.id, privacy: .private(mask: .hash)) reason=\(FailureReason.of(error), privacy: .public)")
            }
        }
        isLoading = false
    }

    /// Deliberate restart: a jump to 0 counts as a user action and is synced
    /// immediately (no conflict dialog).
    private func restartFromBeginning() async {
        if coordinator.activeItem?.id == entry.id, let vm = coordinator.viewModel {
            await vm.seek(to: 0)
            vm.play()
        } else {
            await coordinator.open(item: entry.item)
            await coordinator.viewModel?.seek(to: 0)
        }
    }

    // MARK: - Chapters

    private func chapterLink(_ chapters: [ABSChapter], isFallback: Bool, isHero: Bool) -> some View {
        NavigationLink {
            DetailChapterList(
                bookTitle: shownItem.title,
                chapters: chapters,
                coordinator: coordinator,
                entry: entry
            )
        } label: {
            HStack {
                // A fallback book navigates PARTS. The row must not
                // promise chapters the selector then calls "Teil N".
                Label(ChapterModel.selectorLabel(isMusic: false, isFallback: isFallback),
                      systemImage: "list.bullet")
                    .font(.subheadline)
                    .foregroundStyle(isHero ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer()
                Text("\(chapters.count)")
                    .font(.subheadline)
                    .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.secondary))
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.secondary))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .modifier(AdaptiveGlassBackground(shape: buttonShape))
        .padding(.horizontal)
    }

    /// If THIS book is currently the active session, a dedicated, truly
    /// observing subview is used (see `ActivePlayButton`). Otherwise the button
    /// does not reliably react to play/pause changes, for the same reason as the
    /// mini-player: `coordinator` itself only notifies when `viewModel` is
    /// re-SET, not when values WITHIN it (like `isPlaying`) change.
    @ViewBuilder
    private func playButton(withPadding: Bool) -> some View {
        Group {
            if let vm = coordinator.viewModel, coordinator.activeItem?.id == entry.id {
                ActivePlayButton(viewModel: vm, shape: buttonShape)
            } else {
                Button {
                    Task { await coordinator.open(item: entry.item) }
                } label: {
                    HStack {
                        if isThisBookLoading {
                            ProgressView()
                            Text("Starting…")
                        } else {
                            Image(systemName: "play.fill")
                            Text(playButtonLabel)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.primary)
                }
                .modifier(AdaptiveGlassBackground(shape: buttonShape))
                .disabled(isThisBookLoading)
                .accessibilityIdentifier("book-play")
            }
        }
        .padding(.horizontal, withPadding ? 16 : 0)
    }

    // MARK: - Zusatzinfos

    @ViewBuilder
    private func infoSection(withPadding: Bool) -> some View {
        let narrator = detail?.media.metadata?.narratorName
        let series = detail?.media.metadata?.seriesName
        let genres = detail?.media.metadata?.genres
        let year = detail?.media.metadata?.publishedYear?.value
        let duration = detail?.media.duration

        let hasAnyInfo = [narrator, series, year].contains { $0?.isEmpty == false }
            || (genres?.isEmpty == false)
            || (duration ?? 0) > 0

        // `withPadding` also reveals whether this is the hero view (sits on the
        // colored gradient background, so needs white text) or the side-by-side
        // layout (normal system background, normal adaptive colors suffice).
        if hasAnyInfo {
            VStack(alignment: .leading, spacing: 6) {
                if let series, !series.isEmpty {
                    infoRow(label: "Series", value: series, isHero: withPadding)
                }
                if let narrator, !narrator.isEmpty {
                    infoRow(label: "Narrator", value: narrator, isHero: withPadding)
                }
                if let genres, !genres.isEmpty {
                    infoRow(label: "Genre", value: genres.joined(separator: ", "), isHero: withPadding)
                }
                if let year, !year.isEmpty {
                    infoRow(label: "Released", value: year, isHero: withPadding)
                }
                if let duration, duration > 0 {
                    infoRow(label: "Total Duration", value: formattedDuration(duration), isHero: withPadding)
                }
                // The card's words for the same moment (`ListeningMoment`):
                // the newer of the local and the server stand, or playing now.
                if let heard = CardStatusLine.lastHeard(itemId: entry.id,
                                                        server: currentProgress?.lastUpdate ?? 0) {
                    infoRow(label: "Last Listened", value: heard, isHero: withPadding)
                }
            }
            .padding(.horizontal, withPadding ? 16 : 0)
        }
    }

    private func infoRow(label: LocalizedStringKey, value: String, isHero: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.secondary))
                .frame(width: infoLabelWidth, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(isHero ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer()
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        DurationText.length(seconds: seconds)
    }

    /// Server descriptions often contain raw HTML (`<p>`, `<br>`, …) instead of
    /// plain text. Converts paragraph/line breaks into real breaks, removes all
    /// remaining tags and decodes the most common HTML entities. Deliberately a
    /// simple cleanup instead of a full HTML render, which is enough for
    /// plain-text descriptions.
    private static func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.caseInsensitive, .regularExpression])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [String: String] = [
            "&amp;": "&", "&nbsp;": " ", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Mark as played

    /// Read the CURRENT library entry, not the navigation-time snapshot, so
    /// a restart that cleared the finished flag (markUnfinishedLocally) is
    /// reflected here immediately. Otherwise the page kept showing 'gehört'.
    private var currentProgress: BookProgress? {
        // A catalog title's progress lives on the DEVICE (localPosition),
        // not in any library list. Same witness the continue rows read.
        if isCatalogTitle {
            guard let mark = ListeningStore.mark(entry.id) else { return nil }
            return BookProgress.fromDeviceMark(position: mark.position, updatedAtMs: mark.updatedAtMs,
                                               markedDuration: mark.duration,
                                               itemDuration: entry.item.media?.duration,
                                               tail: PlayedTail.seconds(forItemId: entry.id))
        }
        // The same source as the route that opened the page: grid and shelves.
        return libraryViewModel?.shelvedEntry(id: entry.id)?.progress
            ?? entry.progress
    }

    private var isFinished: Bool {
        isFinishedOverride ?? (currentProgress?.countsAsFinished ?? false)
    }

    /// The finished toggle: the true end, or this page's own last mark.
    private var finishGesture: ProgressMark.MarkGesture {
        ProgressMark.markGesture(atTrueEnd: isFinishedOverride ?? currentProgress?.atTrueEnd ?? false)
    }

    /// `compact`: the short word, so both buttons share one row.
    private func markAsFinishedButton(compact: Bool) -> some View {
        let gesture = finishGesture
        let title = switch (gesture.marksPlayed, compact) {
        case (true, false): String(localized: "Mark as Finished")
        case (false, false): String(localized: "Mark as Unfinished")
        case (true, true): String(localized: "Mark Finished")
        case (false, true): String(localized: "Mark Unfinished")
        }
        return Button {
            Task { await toggleFinishedMark() }
        } label: {
            Label(title, systemImage: gesture.marksPlayed ? "checkmark.circle" : "checkmark.circle.fill")
                .lineLimit(1)
            .font(.subheadline)
            .foregroundStyle(.primary)
            // Same height source as the download capsule next to it.
            .frame(maxWidth: .infinity, minHeight: CoverBadge.detailControl)
            .padding(.vertical, 2)
        }
        .modifier(AdaptiveGlassBackground(shape: Capsule()))
    }

    private func toggleFinishedMark() async {
        errorMessage = nil
        let target = finishGesture.marksPlayed
        let outcome = await BookFinishMark.apply(entry, target: target, progress: currentProgress,
                                                 provider: detailProvider, coordinator: coordinator,
                                                 libraryViewModel: libraryViewModel)
        if let reason = outcome.reason {
            errorMessage = reason
        } else {
            isFinishedOverride = target
        }
    }

    // MARK: - Download

    /// `compact`: the short word, so both buttons share one row.
    @ViewBuilder
    private func downloadSection(compact: Bool) -> some View {
        // The secondary buttons follow the RIGHTS. A catalog title has no
        // download path today (the copy stays gated on a stated licence,
        // and the shellac records never state one); a download button here
        // would OPEN a way every other surface keeps closed.
        // Marking as finished stays: that is the listener's own statement.
        if isCatalogTitle {
            EmptyView()
        } else {
            BookDownloadCapsule(itemId: entry.id, canStart: detail != nil && isOnline, compact: compact) {
                await startDownloadWithWiFiCheck()
            }
        }
    }

    private func startDownloadWithWiFiCheck() async {
        // The warning can be turned off in the settings (default ON).
        let warn = AppStorageKeys.warnCellularDownloadValue
        if warn, !(await NetworkStatus.isOnWiFi()) {
            showWiFiWarning = true
        } else {
            await reallyStartDownload()
        }
    }

    private func reallyStartDownload() async {
        guard let detail else { return }
        // The provider that PRODUCED this detail, not the one that happens to
        // play. `detailProvider` already routes a catalog title by its id for
        // exactly that reason; the download used to ignore it.
        await downloadManager.download(item: detail, provider: detailProvider, kind: .audiobooks)
    }

    private var playButtonLabel: String {
        if let p = currentProgress, p.isStarted { return String(localized: "Continue Listening") }
        return String(localized: "Play")
    }

    /// True while the coordinator is loading exactly this book. So the spinner
    /// spins only on the right button, not when another book happens to load.
    private var isThisBookLoading: Bool {
        coordinator.isLoading && coordinator.activeItem?.id == entry.id
    }
}

/// The download capsule of the detail page: done with size, running with
/// progress, paused, failed, or the offer to save. It is the only part of the
/// page that reads the download state, so it is the part that observes the
/// manager; a progress publish re-runs this capsule, never the page with its
/// chapter list. Starting stays with the page, which owns the Wi-Fi question.
private struct BookDownloadCapsule: View {
    @Environment(\.itemRouter) private var router
    private let downloadManager = DownloadManager.shared
    @ObservedObject private var downloadStock = DownloadManager.stock
    @ObservedObject private var downloadProgress: ItemDownloadProgress
    let itemId: String
    /// The page knows whether a start can work: the detail must be loaded and
    /// the device online.
    let canStart: Bool
    /// The short word at the start, so the capsule shares one row with
    /// the mark button.
    let compact: Bool
    let start: () async -> Void

    init(itemId: String, canStart: Bool, compact: Bool, start: @escaping () async -> Void) {
        self.itemId = itemId
        self.canStart = canStart
        self.compact = compact
        self.start = start
        _downloadProgress = ObservedObject(wrappedValue: DownloadManager.progress.item(itemId))
    }

    var body: some View {
        Group {
            if downloadManager.isDeletableDownload(itemId: itemId) {
                // Same visual language as the neighbouring buttons: glass
                // capsule, primary/secondary text. No signal colors.
                // Compact: the stored glyph + size says it all. The full label
                // ("Available Offline") wraps badly in the half-width capsule
                // and lives on as the accessibility label instead.
                HStack(spacing: 8) {
                    // The labelled capsule stays (decided), with the one
                    // symbol of the downloaded mark.
                    Image(systemName: DownloadedMark.symbol)
                        .foregroundStyle(.primary)
                    Text(ByteCountFormatter.string(
                        fromByteCount: downloadStock.sizeByItem[itemId] ?? 0,
                        countStyle: .file
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    // Re-check the download: fetches exactly the tracks that
                    // are missing or were stored corrupted (tiny error pages).
                    // 44pt hit areas; the capsule keeps its height via
                    // reduced vertical padding.
                    Button {
                        Task { await start() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                            .frame(width: CoverBadge.detailControl, height: CoverBadge.detailControl)
                            .contentShape(Rectangle())
                    }
                    Button {
                        downloadManager.deleteDownload(itemId: itemId)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                            .frame(width: CoverBadge.detailControl, height: CoverBadge.detailControl)
                            .contentShape(Rectangle())
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Available Offline"))
                .accessibilityIdentifier("book-download-done")
                // ONE height source for the whole action row. Every
                // capsule is min. the 44 pt control height + 2 pt padding, so
                // the offline and mark-played capsules always line up.
                .frame(minHeight: CoverBadge.detailControl)
                .padding(.vertical, 2)
                .padding(.horizontal, 14)
                .modifier(AdaptiveGlassBackground(shape: Capsule()))
                // Hug the natural width so the size text never truncates.
                // The mark-played capsule takes the remaining row width instead.
                .fixedSize(horizontal: true, vertical: false)
            } else if let phase = downloadManager.phase[itemId] {
                switch phase {
                case .downloading(let progress):
                    HStack(spacing: 8) {
                        // Unknown total (server without Content-Length) → an
                        // indeterminate bar and no percentage instead of a
                        // bar frozen at 0%.
                        if progress < 0 {
                            ProgressView().tint(AppTheme.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ProgressView(value: progress)
                                .tint(AppTheme.accent)
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                        Button { downloadManager.pauseDownload(itemId: itemId) } label: {
                            Image(systemName: "pause.circle")
                                .foregroundStyle(.primary)
                        }
                        Button { downloadManager.cancelDownload(itemId: itemId) } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: CoverBadge.detailControl)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 14)
                    .modifier(AdaptiveGlassBackground(shape: Capsule()))
                case .paused(let progress):
                    HStack(spacing: 8) {
                        // Unknown total → no bar frozen at 0%, just the label.
                        if progress < 0 {
                            Text("Paused").font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ProgressView(value: progress)
                                .tint(.secondary)
                        }
                        Button { downloadManager.resumeDownload(itemId: itemId) } label: {
                            Label("Resume", systemImage: "play.circle")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.accent)
                        }
                        Button { downloadManager.cancelDownload(itemId: itemId) } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: CoverBadge.detailControl)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 14)
                    .modifier(AdaptiveGlassBackground(shape: Capsule()))
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(AppTheme.accent)
                            .lineLimit(2)
                        Button {
                            Task { await start() }
                        } label: {
                            // Completed tracks are kept. Only missing files load.
                            Label("Load Missing Files", systemImage: "arrow.down.circle")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .modifier(AdaptiveGlassBackground(shape: Capsule()))
                    }
                }
            } else if MediaDownloadOffer.isPossible(router.provider(itemId).capabilities) {
                Button {
                    Task { await start() }
                } label: {
                    // A leftover partial folder means only missing files load.
                    Label(
                        compact
                            ? String(localized: "Offline")
                            : downloadManager.hasPartialDownload(itemId: itemId)
                                ? String(localized: "Load Missing Files")
                                : String(localized: "Save Offline"),
                        systemImage: "arrow.down.circle"
                    )
                    .lineLimit(1)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: CoverBadge.detailControl)
                    .padding(.vertical, 2)
                }
                .modifier(AdaptiveGlassBackground(shape: Capsule()))
                // The spoken label keeps the full words in the compact form.
                .accessibilityLabel(downloadManager.hasPartialDownload(itemId: itemId)
                                    ? Text("Load Missing Files") : Text("Save Offline"))
                // Offline a download can't start. Disable instead of failing.
                .disabled(!canStart)
                // Locale-independent handles for the offline states. The
                // labels are translated AND state-dependent ("Save Offline"
                // vs. "Load Missing Files"), so they cannot serve as anchors.
                .accessibilityIdentifier("book-download-start")
            }
        }
    }
}

/// Chapter list of the detail page (lazy List. Books sometimes have 400+ chapters).
/// Tapping starts playback from this chapter; for the active book the current
/// chapter is highlighted.
private struct DetailChapterList: View {
    let bookTitle: String
    let chapters: [ABSChapter]
    @ObservedObject var coordinator: PlayerCoordinator
    let entry: LibraryEntry
    /// In the right column of the wide book page instead of a page of its
    /// own: no title of its own, the page's ground shows through.
    var embedded = false

    private var isActiveBook: Bool { coordinator.activeItem?.id == entry.id }

    var body: some View {
        if embedded {
            rows
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
        } else {
            rows
                .navigationTitle(bookTitle)
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var rows: some View {
        List(chapters) { chapter in
            Button {
                Task { await play(chapter) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        // A jump mark names its start already.
                        if !ChapterModel.namesItsStart(chapter) {
                            Text(ChapterModel.timeLabel(chapter.start))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if isActiveBook, coordinator.viewModel?.currentChapter == chapter {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(AppTheme.accent)
                    } else {
                        Text(durationText(chapter))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(embedded ? Color.clear : nil)
            // At the fold the gutter the frame counts on (`FoldColumns`).
            .listRowInsets(embedded ? EdgeInsets(top: 8, leading: FoldSplit.pageGutter, bottom: 8, trailing: 20) : nil)
        }
    }

    private func play(_ chapter: ABSChapter) async {
        if isActiveBook, let vm = coordinator.viewModel {
            vm.jumpToChapter(chapter)
            vm.play()
        } else {
            await coordinator.open(item: entry.item)
            await coordinator.viewModel?.seek(to: chapter.start)
        }
    }

    private func durationText(_ chapter: ABSChapter) -> String {
        DurationText.length(minutes: max(1, Int((chapter.end - chapter.start) / 60)))
    }
}

/// Play/pause button for the case that THIS book is already the active session.
/// Its own view so `viewModel` is truly observed as @ObservedObject. Otherwise
/// the button does not reliably react to play/pause changes (see the explanation
/// in `BookDetailScreen.playButton`).
private struct ActivePlayButton<S: Shape>: View {
    @ObservedObject var viewModel: PlayerViewModel
    let shape: S

    var body: some View {
        Button {
            viewModel.togglePlayPause()
        } label: {
            HStack {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                Text(viewModel.isPlaying ? String(localized: "Pause") : String(localized: "Resume"))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.primary)
        }
        .modifier(AdaptiveGlassBackground(shape: shape))
        // The active button is a SECOND control at the same place. Without
        // its own handle nothing can tell "this book is running" from "this
        // book offers to start".
        .accessibilityIdentifier("book-play-toggle")
    }
}
