// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Large "Continue" card for audiobooks. Analogous to the podcast card: cover
/// on top, below it a text area in the cover's average color (soft transition),
/// remaining · last played, title/author and current chapter. Tapping the card
/// resumes directly (Apple style); detail via the info pill at the bottom left,
/// more actions via long-press.
struct BookFeaturedCard: View {
    @Environment(\.itemRouter) private var router
    // The card does not observe DownloadManager/NetworkMonitor at the
    // whole-card level. A download-progress tick published `phase` on every
    // observing view, re-running the (previously unmemoized) chapter validation
    // per card per tick. A very visible hitch with a 186-part book. Now the
    // download badge observes `phase` on its own, the offline dimming observes
    // the network on its own (OfflineDimming), and the chapter title is memoized.
    let entry: LibraryEntry
    @ObservedObject var playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel
    @StateObject private var colorLoader = CoverColorLoader()
    /// Chapters are loaded lazily from the item detail. The library list comes
    /// "minified" and contains no chapters (see loadChapters).
    @State private var loadedChapters: [ABSChapter]?
    /// Memoized current-chapter title. Recomputed ONLY when the loaded
    /// chapters or the playback position change, never per body eval.
    @State private var currentChapterTitle: String?
    private let width = CardMetrics.featuredCardWidth
    // Pill reserve and line heights scale with Dynamic Type. At AX
    // sizes the overlay pill used to grow into the text block.
    @ScaledMetric(relativeTo: .subheadline) private var pillReserve: CGFloat = 40
    @ScaledMetric(relativeTo: .headline) private var titleMinHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .subheadline) private var authorMinHeight: CGFloat = 20

    private var coverURL: URL? { router.coverURL(entry.id) }

    var body: some View {
        Button {
            Task { await playerCoordinator.open(item: entry.item) }
        } label: {
            cardBody
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .background(colorLoader.accent)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Fixed-width eye-catcher card: cap the type size so AX4/AX5 stay
        // legible instead of exploding (content surfaces scale fully).
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .task(id: coverURL) { await colorLoader.load(from: coverURL) }
        .task(id: entry.id) { await loadChapters(); recomputeChapter() }
        // Recompute the chapter title on a position change (the ONLY other
        // input). Not on every redraw, and never on a download tick.
        .onChange(of: entry.progress?.currentTime) { recomputeChapter() }
        .overlay(alignment: .bottomLeading) { infoPill.padding(12) }
        // The marks at the top right of the cover: kind in a mixed row,
        // downloaded or not available offline.
        .overlay(alignment: .topTrailing) { CardMarks(itemId: entry.id, lock: nil) }
        // The download ring at the CARD's bottom-right corner. A tap on the
        // running ring cancels instead of triggering the card's play action
        // underneath; downloading is an entry of the long-press menu below.
        .overlay(alignment: .bottomTrailing) {
            CardDownloadBadge(itemId: entry.id)
            .padding(12)
        }
        .modifier(BookCellContextMenu(
            entry: entry,
            playerCoordinator: playerCoordinator,
            libraryViewModel: libraryViewModel,
            // This card exists ONLY in Continue contexts (the
            // audiobook row, Home's row and both full pages), so the entry
            // belongs on it wherever it appears.
            showsContinueHide: true
        ))
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The cover still dims when offline-unavailable; the wifi.slash
            // marker itself lives in the card-corner badge. The shared
            // MediaAvailabilityScope observes the globals for this item, so a
            // reconnect/download updates ONLY the cover. The card observes nothing.
            MediaAvailabilityScope(itemId: entry.id) { unavailable in
                podcastArtwork(url: coverURL, size: width, corner: 0, thumbnailPixel: 800)
                    .opacity(unavailable ? 0.5 : 1)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, colorLoader.accent],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: width * 0.3)
            }

            VStack(alignment: .leading, spacing: 5) {
                let sub = CardStatusLine.bookText(entry)
                if !sub.isEmpty {
                    CardStatusLine(text: sub)
                }
                // Fixed heights for the variable lines (title 1 line, author,
                // chapter). Otherwise a card with more text gets taller than its
                // neighbours and the row looks uneven.
                Text(entry.item.title)
                    .font(.headline).foregroundStyle(.white).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: titleMinHeight, alignment: .topLeading)
                Text(entry.item.author ?? " ")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: authorMinHeight, alignment: .topLeading)
                Text(currentChapterTitle ?? " ")
                    .font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 6, alignment: .topLeading)
            }
            .padding(14)
            .padding(.bottom, pillReserve)   // room for the overlay pill
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The card itself is tap-to-play; the pill therefore does NOT play again but
    /// opens the detail page (info). Shared anatomy (5219a7).
    private var infoPill: some View {
        CardDetailPill(value: entry.id)
    }

    // MARK: - Rich card content

    /// Recompute the memoized chapter title from the current inputs. Called
    /// only when the chapters load or the position changes (see the modifiers),
    /// never per body eval. The validation over the whole chapter list used to
    /// run per card per download tick.
    private func recomputeChapter() {
        currentChapterTitle = Self.chapterTitle(
            raw: loadedChapters ?? entry.item.media?.chapters,
            currentTime: entry.progress?.currentTime,
            duration: entry.item.media?.duration)
    }

    /// Current-chapter title (pure, tested). Derived from the VALIDATED list,
    /// never the raw server chapters. `last(where: t >= start)` on raw chapters
    /// names a phantom chapter for a coverage-fallback book once the position is
    /// past the last real chapter; `current` returns nil there → no wrong label.
    nonisolated static func chapterTitle(raw: [ABSChapter]?, currentTime: Double?,
                                         duration: Double?) -> String? {
        guard let raw, !raw.isEmpty, let t = currentTime else { return nil }
        let validated = ChapterModel.validated(raw, duration: duration ?? 0)
        return ChapterModel.current(at: t, in: validated)?.title
    }

    /// Fetch the book's chapters once from the detail (the list is "minified",
    /// without chapters). Result cached process-wide so scrolling/redrawing
    /// triggers no new request.
    private func loadChapters() async {
        if let existing = entry.item.media?.chapters, !existing.isEmpty { return }
        if let cached = FeaturedChapterCache.shared.chapters(for: entry.id) {
            loadedChapters = cached
            return
        }
        let provider = router.provider(entry.id)
        // The card appearing is an automatic question.
        guard let detail = try? await LookupOccasion.automatic({
            try await provider.fetchItemDetail(itemId: entry.id)
        }) else { return }
        let chapters = detail.media.chapters ?? []
        FeaturedChapterCache.shared.store(chapters, for: entry.id)
        loadedChapters = chapters
    }
}

/// Process-wide chapter cache for the "Continue" cards. Fetch the detail once
/// per book, then from memory.
@MainActor
final class FeaturedChapterCache {
    static let shared = FeaturedChapterCache()
    private var cache: [String: [ABSChapter]] = [:]
    func chapters(for id: String) -> [ABSChapter]? { cache[id] }
    func store(_ chapters: [ABSChapter], for id: String) { cache[id] = chapters }
}

