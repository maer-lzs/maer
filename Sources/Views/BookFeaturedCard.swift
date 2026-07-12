import SwiftUI

/// Large "Continue" card for audiobooks — analogous to the podcast card: cover
/// on top, below it a text area in the cover's average color (soft transition),
/// remaining · last played, title/author and current chapter. Tapping the card
/// resumes directly (Apple style); detail via the info pill at the bottom left,
/// more actions via long-press.
struct BookFeaturedCard: View {
    let entry: LibraryEntry
    @ObservedObject var playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel
    @StateObject private var colorLoader = CoverColorLoader()
    /// Chapters are loaded lazily from the item detail — the library list comes
    /// "minified" and contains no chapters (see currentChapter).
    @State private var loadedChapters: [ABSChapter]?
    private let width: CGFloat = 235

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
        .task(id: coverURL) { await colorLoader.load(from: coverURL) }
        .task(id: entry.id) { await loadChapters() }
        .overlay(alignment: .bottomLeading) { infoPill.padding(12) }
        .overlay(alignment: .bottomTrailing) {
            BookDownloadButton(entry: entry, provider: playerCoordinator.provider, tint: .white)
                .padding(14)
        }
        .modifier(BookCellContextMenu(
            entry: entry,
            playerCoordinator: playerCoordinator,
            libraryViewModel: libraryViewModel
        ))
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            podcastArtwork(url: coverURL, size: width, corner: 0, thumbnailPixel: 800)
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
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .topLeading)
                Text(entry.item.author ?? " ")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
                Text(currentChapter ?? " ")
                    .font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 6, alignment: .topLeading)
            }
            .padding(14)
            .padding(.bottom, 40)   // Platz für die Overlay-Pille
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

    // MARK: - Reicher Karten-Inhalt

    private var remainingText: String? {
        guard let p = entry.progress, p.isStarted else { return nil }
        return p.remainingText(bookDuration: entry.item.media?.duration)
    }

    private var lastPlayedText: String? {
        guard let ts = entry.progress?.lastUpdate, ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts / 1000).formatted(.relative(presentation: .named))
    }

    /// Aktuelles Kapitel — aus den (lazy nachgeladenen) Kapiteln, sonst aus den
    /// evtl. schon vorhandenen Item-Daten.
    private var currentChapter: String? {
        guard let chapters = loadedChapters ?? entry.item.media?.chapters,
              !chapters.isEmpty, let t = entry.progress?.currentTime else { return nil }
        return chapters.last(where: { t >= $0.start })?.title
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

/// Download control for an audiobook (state from the DownloadManager) —
/// visually identical to the podcast card: arrow → ring while loading →
/// checkmark when downloaded.
struct BookDownloadButton: View {
    let entry: LibraryEntry
    let provider: any AudioProvider
    var tint: Color = .secondary
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        if downloads.isDownloaded(itemId: entry.id) {
            Image(systemName: "checkmark.circle")
                .font(.title3).foregroundStyle(tint)
                .accessibilityLabel(Text("Downloaded"))
        } else if case .downloading(let f) = downloads.phase[entry.id] {
            ProgressView(value: f).progressViewStyle(.circular).scaleEffect(0.7)
                .accessibilityLabel(Text("Downloading"))
        } else {
            Button {
                Task {
                    guard let detail = try? await provider.fetchItemDetail(itemId: entry.id) else { return }
                    await DownloadManager.shared.download(item: detail, provider: provider)
                }
            } label: {
                Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Download"))
        }
    }
}
