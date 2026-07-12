import SwiftUI

/// Große „Fortsetzen"-Karte für Hörbücher — analog zur Podcast-Karte: Cover
/// oben, darunter eine Textfläche in der Cover-Durchschnittsfarbe (weicher
/// Übergang), Titel/Autor + Fortschritt, Play-Pille unten links. Tap öffnet die
/// Buchdetailseite (wertbasiert, damit ein Medien-Tab-Reset zurückpoppt).
struct BookFeaturedCard: View {
    let entry: LibraryEntry
    @ObservedObject var playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel
    @StateObject private var colorLoader = CoverColorLoader()
    private let width: CGFloat = 235

    private var coverURL: URL? { AppSession.shared.coverURL(forItemId: entry.id) }

    var body: some View {
        NavigationLink(value: entry.id) {
            cardBody
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .background(colorLoader.accent)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: coverURL) { await colorLoader.load(from: coverURL) }
        // Play als Overlay → eigener Tap-Bereich, keine Navigation.
        .overlay(alignment: .bottomLeading) { playPill.padding(12) }
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
                if let p = entry.progress, p.isStarted,
                   let remaining = p.remainingText(bookDuration: entry.item.media?.duration) {
                    Text(remaining)
                        .font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
                Text(entry.item.title)
                    .font(.headline).foregroundStyle(.white).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let author = entry.item.author {
                    Text(author).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
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
}
