import SwiftUI

/// Stapel-Kachel für eine Serie im Bibliotheks-Grid: oberstes Cover, dahinter
/// die echten Cover der nächsten Bände leicht versetzt/gedreht; Zähler-Badge
/// in derselben Größenklasse wie die Cover-Badges in BookCoverView.
struct SeriesStackCell: View {
    let name: String
    let entries: [LibraryEntry]
    let cellWidth: CGFloat
    let coverURL: (String) -> URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                // Bis zu zwei echte Folge-Cover hinter dem obersten.
                ForEach(Array(entries.dropFirst().prefix(2).enumerated()), id: \.element.id) { index, entry in
                    CachedAsyncImage(url: coverURL(entry.id)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.3))
                    }
                    .frame(width: cellWidth - 14, height: cellWidth - 14)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .rotationEffect(.degrees(index == 0 ? 5 : -5))
                    .offset(y: -6)
                    .opacity(0.9)
                }
                BookCoverView(
                    url: coverURL(entries[0].id),
                    progress: nil,
                    itemId: nil,
                    size: cellWidth
                )
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            }
            .padding(.top, 10)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 2) {
                    Image(systemName: "square.stack")
                    Text("\(entries.count)")
                }
                .font(.system(size: cellWidth * 0.1, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(AppTheme.accent, in: Capsule())
                .padding(4)
            }
            Text(name)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text("\(entries.count) Bücher")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: cellWidth, alignment: .leading)
    }
}
