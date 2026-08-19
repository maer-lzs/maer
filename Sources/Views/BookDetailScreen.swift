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
    let entry: LibraryEntry
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject private var downloadManager = DownloadManager.shared

    @State private var detail: LibraryItemDetail?
    @State private var isLoading = true
    @State private var showWiFiWarning = false
    @State private var copiedReport = false
    @State private var isFinishedOverride: Bool?
    @State private var errorMessage: String?
    @StateObject private var colorLoader = CoverColorLoader()
    /// D13/B12: label column scales with Dynamic Type — 90pt fixed broke
    /// "Erzähler/Erschienen" mid-word at AX sizes.
    @ScaledMetric(relativeTo: .caption) private var infoLabelWidth: CGFloat = 90

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var systemColorScheme

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }


    /// Deliberately screen width instead of GeometryReader — the cover should
    /// always use exactly the full device width (not some ScrollView width).
    /// Via the WindowScene instead of UIScreen.main (deprecated iOS 26).
    private var heroCoverSize: CGFloat {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }.first
        return screen?.bounds.width ?? 400
    }

    private var heroCover: some View {
        coverImageContent
            .frame(width: heroCoverSize, height: heroCoverSize)
            .clipped()
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
            // Y6b: the author portrait floats on the SEAM between cover and
            // gradient (avatar-over-banner pattern), trailing side — mostly
            // above the edge, dipping slightly below it.
            .overlay(alignment: .bottomTrailing) {
                authorPortrait
                    .padding(.trailing, 20)
                    .offset(y: Self.portraitSize / 2 - 16)
            }
            .frame(maxWidth: .infinity)
    }

    private var coverImageContent: some View {
        CachedAsyncImage(url: AppSession.shared.coverURL(forItemId: entry.id)) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary))
        }
    }

    /// Title/author/progress — centered and white for the hero view (it sits on
    /// the colored gradient background, where `.primary` is not enough, that
    /// would be black and unreadable in light system mode), left-aligned with
    /// normal adaptive colors for the side-by-side layout (there the background
    /// is the normal system background).
    private func titleBlock(alignment: HorizontalAlignment) -> some View {
        let isHero = alignment == .center
        return VStack(alignment: alignment, spacing: 6) {
            Text(entry.item.title)
                .font(.title2).bold()
                .multilineTextAlignment(isHero ? .center : .leading)
                .foregroundStyle(isHero ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            if let author = entry.item.author {
                // F3: round author portrait next to the author line — ONLY when
                // the server ships an image (no placeholder, no initials; the
                // row looks like before otherwise, same rule as music artists
                // without a picture). Tapping filters the library to this
                // author — the image is function, not decoration — and is only
                // active when the author has MORE than one work here.
                // Y6b: in the hero the portrait FLOATS on the cover edge (see
                // heroCover overlay) — the author line stays pure text. The
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

    /// F3: portrait URL — only for ABS books whose expanded payload carries an
    /// author id; the request itself only renders when the image loads.
    private var authorImageURL: URL? {
        guard let authorId = detail?.media.metadata?.authors?.first?.id else { return nil }
        return (coordinator.provider as? APIClient)?.authorImageURL(authorId: authorId)
    }

    /// F3: the author's works in the library — the tap filter is only active
    /// for more than one work (pure rule, tested).
    private var authorWorks: [LibraryEntry] {
        guard let author = entry.item.author else { return [] }
        return libraryViewModel.entries.filter { $0.item.author == author }
    }

    /// Y6b: portrait diameter — floats on the cover/gradient seam.
    private static let portraitSize: CGFloat = 72

    @ViewBuilder
    private var authorPortrait: some View {
        if let url = authorImageURL {
            let works = authorWorks
            // Frame INSIDE the success branch: while loading (and when the
            // server has no image) nothing renders and nothing reserves space —
            // the row looks exactly like today.
            let portrait = CachedAsyncImage(url: url, useThumbnail: true) { image in
                // Y56: a clean round portrait in the established form language —
                // the show-cover corner badge's look (crisp image + thin white
                // rim), only ROUND. No smear, no dissolve, no grayscale.
                image.resizable().aspectRatio(contentMode: .fill)
                    .frame(width: Self.portraitSize, height: Self.portraitSize)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
            } placeholder: {
                // Y6 root cause: an `EmptyView` placeholder never "appears",
                // so CachedAsyncImage's `.task(id:)` never fired and the load
                // never STARTED — server 200s notwithstanding. A zero-sized
                // real view participates in the lifecycle while still
                // reserving no visible space without an image.
                Color.clear.frame(width: 0, height: 0)
            }
            if LibraryViewModel.authorFilterEnabled(workCount: works.count),
               let author = entry.item.author {
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

    /// Side-by-side layout (iPad / iPhone landscape): cover column pinned to
    /// the screen edges on the left, scrollable info column on the right.
    /// iPhone: full-height SHARP cover (screen height ≈ 390pt fits the cache
    /// resolution). iPad: a full-height cover would need >2300px source —
    /// instead a heavily BLURRED ambient panel (blur hides any resolution)
    /// with the sharp cover floating on top.
    private var sideBySideLayoutView: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if isPhone {
                    coverImageContent
                        .frame(width: geo.size.height, height: geo.size.height)
                        .clipped()
                } else {
                    ZStack {
                        coverImageContent
                            .frame(width: 420, height: geo.size.height)
                            .clipped()
                            .blur(radius: 45)
                            .overlay(Color.black.opacity(systemColorScheme == .dark ? 0.3 : 0.1))
                        BookCoverView(
                            url: AppSession.shared.coverURL(forItemId: entry.id),
                            progress: currentProgress,
                            itemId: entry.id,
                            size: 320
                        )
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
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
                            HStack(spacing: 12) {
                                downloadSection
                                markAsFinishedButton
                            }
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

    /// Chapter link, error text and description — shared between the portrait and
    /// landscape layouts.
    @ViewBuilder
    private func trailingSections(isHero: Bool) -> some View {
        // V6: use the SAME validated/resolved chapter list the player uses, never
        // the raw server chapters — otherwise a coverage-fallback book shows a
        // different (broken) chapter list here than in the player.
        if let media = detail?.media {
            let resolved = ChapterModel.resolved(
                chapters: media.chapters ?? [], tracks: media.tracks ?? [],
                duration: media.duration ?? 0)
            if !resolved.chapters.isEmpty {
                chapterLink(resolved.chapters, isFallback: resolved.isFallback, isHero: isHero)
            }
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
        }

        // c9529f1: the book's progress diagnosis — the same instrument the
        // podcast sheet carries, in its book view. It exists because a
        // rücksprung could not be PROVEN: it puts server state, local
        // second-backup and the cached detail side by side, each with its
        // timestamp, and names the start the app would pick right now.
        diagnosisSection
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
        let defaults = UserDefaults.standard
        let saved = ListeningStore.backup(entry.id, in: defaults)
        let cached = DownloadManager.shared.loadCachedDetail(forItemId: entry.id)
        let flushed = ListeningStore.flushed(entry.id, in: defaults)
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
            jumpRing: defaults.array(forKey: AppStorageKeys.jumpRing(entry.id)) as? [[Double]] ?? [],
            duration: detail?.media.duration ?? entry.item.media?.duration ?? 0,
            isDownloaded: DownloadManager.shared.isDownloaded(itemId: entry.id),
            // There is no separate progress QUEUE (positions push directly);
            // what exists is the bookmark queue and the sync history — the
            // honest stand-in for "what does this device still owe".
            pendingSyncOperations: BookmarkQueue.shared.pendingOps()
                .filter { $0.itemId == entry.id }.count)
        return ProgressDiagnosis.bookReport(
            title: entry.item.title,
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
        // geometry — its size classes don't change on rotation). Portrait
        // always uses the single-column hero layout, on iPad too.
        GeometryReader { geo in
        let useSideBySideLayout = verticalSizeClass == .compact
            || (geo.size.height > 0 && geo.size.width > geo.size.height)
        ZStack {
            if !useSideBySideLayout {
                // Gradient as the BACKGROUND for the whole upper area, like the
                // large player — cover and title sit freely on top.
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
                // Carry the cover color theme into the side-by-side layout —
                // fading into the SYSTEM tone: black in dark mode, white in
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

            if useSideBySideLayout {
                sideBySideLayoutView
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        VStack(spacing: 8) {
                            heroCover
                            titleBlock(alignment: .center)
                                .padding(.horizontal)
                        }
                        infoSection(withPadding: true)
                        playArea(withPadding: true)
                        HStack(spacing: 12) {
                            downloadSection
                            markAsFinishedButton
                        }
                        .padding(.horizontal)

                        trailingSections(isHero: true)
                    }
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
            }
        }
        // All glass buttons on this page share the book's cover accent.
        // X24: deliberately a PAGE-LOCAL loader (this book's cover), separate
        // from the bar's persistent loader (active item's cover) — both read
        // the same CoverColorLoader.colorCache, so the same cover always
        // yields the same accent. The bar itself lives outside this page and
        // keeps its own accent + the system appearance.
        .environment(\.glassAccent, colorLoader.accent)
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
        .task {
            isLoading = true
            detail = try? await coordinator.provider.fetchItemDetail(itemId: entry.id)
            isLoading = false
        }
        .task(id: entry.id) {
            await colorLoader.load(from: AppSession.shared.coverURL(forItemId: entry.id))
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
                bookTitle: entry.item.title,
                chapters: chapters,
                coordinator: coordinator,
                entry: entry
            )
        } label: {
            HStack {
                // X23: a fallback book navigates PARTS — the row must not
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
    /// observing subview is used (see `ActivePlayButton`) — otherwise the button
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
                if let last = entry.progress?.lastUpdate, last > 0 {
                    infoRow(
                        label: "Last Listened",
                        value: Date(timeIntervalSince1970: last / 1000)
                            .formatted(date: .abbreviated, time: .omitted),
                        isHero: withPadding
                    )
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
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? String(localized: "\(hours) hr \(minutes) min") : String(localized: "\(minutes) min")
    }

    /// Server descriptions often contain raw HTML (`<p>`, `<br>`, …) instead of
    /// plain text. Converts paragraph/line breaks into real breaks, removes all
    /// remaining tags and decodes the most common HTML entities — deliberately a
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

    /// X16b: read the CURRENT library entry, not the navigation-time snapshot, so
    /// a restart that cleared the finished flag (markUnfinishedLocally) is
    /// reflected here immediately — otherwise the page kept showing 'gehört'.
    private var currentProgress: BookProgress? {
        libraryViewModel.entries.first(where: { $0.id == entry.id })?.progress ?? entry.progress
    }

    private var isFinished: Bool {
        isFinishedOverride ?? (currentProgress?.countsAsFinished ?? false)
    }

    private var markAsFinishedButton: some View {
        Button {
            Task { await toggleFinishedMark() }
        } label: {
            Label(
                isFinished ? String(localized: "Mark as Unfinished") : String(localized: "Mark as Finished"),
                systemImage: isFinished ? "checkmark.circle.fill" : "checkmark.circle"
            )
            .font(.subheadline)
            .foregroundStyle(.primary)
            // X22b: same height source as the download capsule next to it.
            .frame(maxWidth: .infinity, minHeight: CoverBadge.detailControl)
            .padding(.vertical, 2)
        }
        .modifier(AdaptiveGlassBackground(shape: Capsule()))
    }

    private func toggleFinishedMark() async {
        errorMessage = nil
        do {
            // Fetch a fresh state instead of trusting the possibly stale
            // `detail` — and then ALWAYS send currentTime + duration + isFinished
            // together. A PATCH with only {"isFinished": ...} leaves it to
            // the server what to do with currentTime — exactly that caused the
            // real progress to be lost after played→unplayed.
            let fresh = try await coordinator.provider.fetchItemDetail(itemId: entry.id)
            let duration = fresh.media.duration ?? 0
            let currentTime = fresh.userMediaProgress?.currentTime ?? 0

            let target = !isFinished
            let writeTime = target ? duration : currentTime
            // Invariant "heard = flies out": marking finished drops it from Up Next.
            if target { PlayQueue.shared.markedPlayed(entry.id) }
            do {
                try await coordinator.provider.updateProgress(
                    itemId: entry.id, currentTime: writeTime, duration: duration, isFinished: target
                )
            } catch {
                // Don't lose the status decision: queue it, the flush sends it later.
                SyncQueue.shared.enqueue(
                    itemId: entry.id, currentTime: writeTime, duration: duration, isFinished: target
                )
            }
            isFinishedOverride = target
            // Without this the library list would keep showing the old state
            // (percentage instead of checkmark) until the app next comes to the
            // foreground.
            await libraryViewModel.refreshProgress()
            // X16c: marking finished behaves like a natural end — if this is the
            // active session, playback stops and auto-continue advances.
            if target { coordinator.markPlayedAndAdvance(itemId: entry.id) }
        } catch {
            if NetworkStatus.isOfflineError(error) {
                // Even the fresh fetch failed (offline): queue with locally known
                // values instead of losing the decision.
                let target = !isFinished
                let duration = entry.item.media?.duration ?? 0
                let currentTime = (entry.progress?.fraction ?? 0) * duration
                SyncQueue.shared.enqueue(
                    itemId: entry.id,
                    currentTime: target ? duration : currentTime,
                    duration: duration,
                    isFinished: target
                )
                isFinishedOverride = target
                // Same rule as in the online branch above: marking finished
                // behaves like a natural end, so the running session stops and
                // auto-continue advances. Offline must not behave differently
                // — the decision is the user's, not the server's.
                if target { coordinator.markPlayedAndAdvance(itemId: entry.id) }
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: - Download

    @ViewBuilder
    private var downloadSection: some View {
        Group {
            if downloadManager.isDownloaded(itemId: entry.id) {
                // Same visual language as the neighbouring buttons: glass
                // capsule, primary/secondary text — no signal colors.
                // Compact: checkmark + size says it all — the full label
                // ("Available Offline") wraps badly in the half-width capsule
                // and lives on as the accessibility label instead.
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.primary)
                    Text(ByteCountFormatter.string(
                        fromByteCount: downloadManager.downloadSize(forItemId: entry.id),
                        countStyle: .file
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    // Re-check the download: fetches exactly the tracks that
                    // are missing or were stored corrupted (tiny error pages).
                    // D8/B7: 44pt hit areas; the capsule keeps its height via
                    // reduced vertical padding.
                    Button {
                        Task { await startDownloadWithWiFiCheck() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                            .frame(width: CoverBadge.detailControl, height: CoverBadge.detailControl)
                            .contentShape(Rectangle())
                    }
                    Button {
                        downloadManager.deleteDownload(itemId: entry.id)
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
                // X22b: ONE height source for the whole action row — every
                // capsule is min. the 44 pt control height + 2 pt padding, so
                // the offline and mark-played capsules always line up.
                .frame(minHeight: CoverBadge.detailControl)
                .padding(.vertical, 2)
                .padding(.horizontal, 14)
                .modifier(AdaptiveGlassBackground(shape: Capsule()))
                // X22: hug the natural width so the size text never truncates —
                // the mark-played capsule takes the remaining row width instead.
                .fixedSize(horizontal: true, vertical: false)
            } else if let phase = downloadManager.phase[entry.id] {
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
                        Button { downloadManager.pauseDownload(itemId: entry.id) } label: {
                            Image(systemName: "pause.circle")
                                .foregroundStyle(.primary)
                        }
                        Button { downloadManager.cancelDownload(itemId: entry.id) } label: {
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
                        Button { downloadManager.resumeDownload(itemId: entry.id) } label: {
                            Label("Resume", systemImage: "play.circle")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.accent)
                        }
                        Button { downloadManager.cancelDownload(itemId: entry.id) } label: {
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
                            Task { await startDownloadWithWiFiCheck() }
                        } label: {
                            // Completed tracks are kept — only missing files load.
                            Label("Load Missing Files", systemImage: "arrow.down.circle")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .modifier(AdaptiveGlassBackground(shape: Capsule()))
                    }
                }
            } else {
                Button {
                    Task { await startDownloadWithWiFiCheck() }
                } label: {
                    // A leftover partial folder means only missing files load.
                    Label(
                        downloadManager.hasPartialDownload(itemId: entry.id)
                            ? String(localized: "Load Missing Files")
                            : String(localized: "Save Offline"),
                        systemImage: "arrow.down.circle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: CoverBadge.detailControl)
                    .padding(.vertical, 2)
                }
                .modifier(AdaptiveGlassBackground(shape: Capsule()))
                // Offline a download can't start — disable instead of failing.
                .disabled(detail == nil || !NetworkMonitor.shared.isConnected)
                // Locale-independent handles for the offline states — the
                // labels are translated AND state-dependent ("Save Offline"
                // vs. "Load Missing Files"), so they cannot serve as anchors.
                .accessibilityIdentifier("book-download-start")
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
        await downloadManager.download(item: detail, provider: coordinator.provider)
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

/// Chapter list of the detail page (lazy List — books sometimes have 400+ chapters).
/// Tapping starts playback from this chapter; for the active book the current
/// chapter is highlighted.
private struct DetailChapterList: View {
    let bookTitle: String
    let chapters: [ABSChapter]
    @ObservedObject var coordinator: PlayerCoordinator
    let entry: LibraryEntry

    private var isActiveBook: Bool { coordinator.activeItem?.id == entry.id }

    var body: some View {
        List(chapters) { chapter in
            Button {
                Task { await play(chapter) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text(formatted(chapter.start))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
        }
        .navigationTitle(bookTitle)
        .navigationBarTitleDisplayMode(.inline)
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

    private func formatted(_ seconds: Double) -> String {
        let t = Int(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func durationText(_ chapter: ABSChapter) -> String {
        let minutes = max(1, Int((chapter.end - chapter.start) / 60))
        return String(localized: "\(minutes) min")
    }
}

/// Play/pause button for the case that THIS book is already the active session.
/// Its own view so `viewModel` is truly observed as @ObservedObject — otherwise
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
        // The active button is a SECOND control at the same place — without
        // its own handle nothing can tell "this book is running" from "this
        // book offers to start".
        .accessibilityIdentifier("book-play-toggle")
    }
}
