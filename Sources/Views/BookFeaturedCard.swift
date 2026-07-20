// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Large "Continue" card for audiobooks — analogous to the podcast card: cover
/// on top, below it a text area in the cover's average color (soft transition),
/// remaining · last played, title/author and current chapter. Tapping the card
/// resumes directly (Apple style); detail via the info pill at the bottom left,
/// more actions via long-press.
struct BookFeaturedCard: View {
    // TF4: the card no longer observes DownloadManager/NetworkMonitor at the
    // whole-card level. A download-progress tick published `phase` on every
    // observing view, re-running the (previously unmemoized) chapter validation
    // per card per tick — a very visible hitch with a 186-part book. Now the
    // download badge observes `phase` on its own, the offline dimming observes
    // the network on its own (OfflineDimming), and the chapter title is memoized.
    let entry: LibraryEntry
    @ObservedObject var playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel
    @StateObject private var colorLoader = CoverColorLoader()
    /// Chapters are loaded lazily from the item detail — the library list comes
    /// "minified" and contains no chapters (see loadChapters).
    @State private var loadedChapters: [ABSChapter]?
    /// TF4: memoized current-chapter title — recomputed ONLY when the loaded
    /// chapters or the playback position change, never per body eval.
    @State private var currentChapterTitle: String?
    private let width = CardMetrics.featuredCardWidth
    // D5/B4: pill reserve and line heights scale with Dynamic Type — at AX
    // sizes the overlay pill used to grow into the text block.
    @ScaledMetric(relativeTo: .subheadline) private var pillReserve: CGFloat = 40
    @ScaledMetric(relativeTo: .headline) private var titleMinHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .subheadline) private var authorMinHeight: CGFloat = 20

    private var coverURL: URL? { AppSession.shared.coverURL(forItemId: entry.id) }

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
        // TF4: recompute the chapter title on a position change (the ONLY other
        // input) — not on every redraw, and never on a download tick.
        .onChange(of: entry.progress?.currentTime) { recomputeChapter() }
        .overlay(alignment: .bottomLeading) { infoPill.padding(12) }
        // X6a: the unified download/offline badge (family) at the CARD's
        // bottom-right corner — a tap cancels/downloads instead of triggering the
        // card's play action underneath.
        .overlay(alignment: .bottomTrailing) {
            CardDownloadBadge(itemId: entry.id, startDownload: {
                guard let detail = try? await playerCoordinator.provider.fetchItemDetail(itemId: entry.id) else { return }
                await DownloadManager.shared.download(item: detail, provider: playerCoordinator.provider)
            })
            .padding(12)
        }
        .modifier(BookCellContextMenu(
            entry: entry,
            playerCoordinator: playerCoordinator,
            libraryViewModel: libraryViewModel
        ))
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // X6a: the cover still dims when offline-unavailable; the wifi.slash
            // marker itself lives in the card-corner badge. TF4: the dimming
            // observes the network on its OWN (OfflineDimming), so a reconnect
            // updates it without the whole card observing anything.
            OfflineDimming(itemId: entry.id) {
                podcastArtwork(url: coverURL, size: width, corner: 0, thumbnailPixel: 800)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, colorLoader.accent],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: width * 0.3)
            }

            VStack(alignment: .leading, spacing: 5) {
                let sub = [remainingText, lastPlayedText].compactMap { $0 }.joined(separator: " · ")
                if !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
                // Fixed heights for the variable lines (title 1 line, author,
                // chapter) — otherwise a card with more text gets taller than its
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
    /// opens the detail page (info).
    private var infoPill: some View {
        NavigationLink(value: entry.id) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.caption)
                Text("Details").font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rich card content

    private var remainingText: String? {
        guard let p = entry.progress, p.isStarted else { return nil }
        return p.remainingText(bookDuration: entry.item.media?.duration)
    }

    private var lastPlayedText: String? {
        guard let ts = entry.progress?.lastUpdate, ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts / 1000).formatted(.relative(presentation: .named))
    }

    /// TF4: recompute the memoized chapter title from the current inputs. Called
    /// only when the chapters load or the position changes (see the modifiers),
    /// never per body eval — the validation over the whole chapter list used to
    /// run per card per download tick.
    private func recomputeChapter() {
        currentChapterTitle = Self.chapterTitle(
            raw: loadedChapters ?? entry.item.media?.chapters,
            currentTime: entry.progress?.currentTime,
            duration: entry.item.media?.duration)
    }

    /// Current-chapter title (pure, tested). V6: derive from the VALIDATED list,
    /// never the raw server chapters — `last(where: t >= start)` on raw chapters
    /// names a phantom chapter for a coverage-fallback book once the position is
    /// past the last real chapter; `current` returns nil there → no wrong label.
    nonisolated static func chapterTitle(raw: [ABSChapter]?, currentTime: Double?,
                                         duration: Double?) -> String? {
        guard let raw, !raw.isEmpty, let t = currentTime else { return nil }
        let validated = ChapterModel.validated(raw, duration: duration ?? 0)
        return ChapterModel.current(at: t, in: validated)?.title
    }

    /// Fetch the book's chapters once from the detail (the list is "minified",
    /// without chapters) — result cached process-wide so scrolling/redrawing
    /// triggers no new request.
    private func loadChapters() async {
        if let existing = entry.item.media?.chapters, !existing.isEmpty { return }
        if let cached = FeaturedChapterCache.shared.chapters(for: entry.id) {
            loadedChapters = cached
            return
        }
        let provider = AppSession.shared.provider(for: entry.id)
        guard let detail = try? await provider.fetchItemDetail(itemId: entry.id) else { return }
        let chapters = detail.media.chapters ?? []
        FeaturedChapterCache.shared.store(chapters, for: entry.id)
        loadedChapters = chapters
    }
}

/// Process-wide chapter cache for the "Continue" cards — fetch the detail once
/// per book, then from memory.
@MainActor
final class FeaturedChapterCache {
    static let shared = FeaturedChapterCache()
    private var cache: [String: [ABSChapter]] = [:]
    func chapters(for id: String) -> [ABSChapter]? { cache[id] }
    func store(_ chapters: [ABSChapter], for id: String) { cache[id] = chapters }
}

/// TF4: dims its content when the title can't play right now (offline + not
/// downloaded). It observes ONLY the network on its own, so a reconnect updates
/// the dimming without the whole `BookFeaturedCard` observing anything — a
/// download-progress tick therefore never re-renders the card (and never
/// re-validates chapters). `isDownloaded` is read non-observed: a download can
/// only COMPLETE while online, and the offline case re-reads it on the next
/// network change.
private struct OfflineDimming<Content: View>: View {
    let itemId: String
    @ViewBuilder var content: Content
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        content.opacity(unavailable ? 0.5 : 1)
    }

    private var unavailable: Bool {
        !networkMonitor.isConnected && !DownloadManager.shared.isDownloaded(itemId: itemId)
    }
}
