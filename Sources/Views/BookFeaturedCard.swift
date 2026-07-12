import SwiftUI

/// Große „Fortsetzen"-Karte für Hörbücher — analog zur Podcast-Karte: Cover
/// oben, darunter eine Textfläche in der Cover-Durchschnittsfarbe (weicher
/// Übergang), Restzeit · zuletzt gehört, Titel/Autor, aktuelles Kapitel und
/// Fortschritt. Tap auf die Karte spielt direkt weiter (Apple-Stil); Detail per
/// Info-Button oben links, mehr Aktionen per Long-Press.
struct BookFeaturedCard: View {
    let entry: LibraryEntry
    @ObservedObject var playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel
    @StateObject private var colorLoader = CoverColorLoader()
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
        .overlay(alignment: .topLeading) { detailButton.padding(10) }
        .overlay(alignment: .bottomLeading) { playPill.padding(12) }
        .modifier(BookCellContextMenu(
            entry: entry,
            playerCoordinator: playerCoordinator,
            libraryViewModel: libraryViewModel
        ))
    }

    private var detailButton: some View {
        NavigationLink(value: entry.id) {
            Image(systemName: "info.circle.fill")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.9), .black.opacity(0.3))
        }
        .buttonStyle(.plain)
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
                Text(entry.item.title)
                    .font(.headline).foregroundStyle(.white).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let author = entry.item.author {
                    Text(author).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
                if let chapter = currentChapter {
                    Text(chapter).font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
                if let p = entry.progress, p.isStarted {
                    ProgressView(value: p.fraction)
                        .tint(.white)
                        .padding(.top, 2)
                }
            }
            .padding(14)
            .padding(.bottom, 40)   // Platz für die Overlay-Pille
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var playPill: some View {
        Button {
            Task { await playerCoordinator.open(item: entry.item) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.caption)
                Text(entry.progress?.isStarted == true
                     ? String(localized: "Resume") : String(localized: "Play"))
                    .font(.subheadline.weight(.medium))
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

    /// Aktuelles Kapitel (nur wenn Kapitel in den Item-Daten vorliegen).
    private var currentChapter: String? {
        guard let chapters = entry.item.media?.chapters, !chapters.isEmpty,
              let t = entry.progress?.currentTime else { return nil }
        return chapters.last(where: { t >= $0.start })?.title
    }
}
