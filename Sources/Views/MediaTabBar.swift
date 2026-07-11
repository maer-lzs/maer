import SwiftUI

/// Glas-Tab-Leiste unten (unter dem Mini-Player) für die Inhaltstypen —
/// Hörbücher/Podcasts/Musik/Radio. Eigenes Glas-Element in derselben
/// Sprache wie Mini-Player und Pille; aktiver Tab in Akzentfarbe. Reine
/// Komponente, der State (selektierter Typ) lebt in der LibraryView.
/// Wird nur eingeblendet, wenn mindestens zwei Typen verfügbar sind.
struct MediaTabBar: View {
    let types: [MediaType]
    @Binding var selected: MediaType

    var body: some View {
        HStack(spacing: 4) {
            ForEach(types) { type in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selected = type }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: type.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                        Text(type.label)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected == type ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .modifier(AdaptiveGlassBackground(shape: Capsule()))
    }
}
