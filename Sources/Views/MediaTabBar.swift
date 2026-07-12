import SwiftUI

/// Glass tab bar at the bottom (below the mini-player) for the content types —
/// audiobooks/podcasts/music/radio. Its own glass element in the same language
/// as mini-player and pill; active tab in the accent color. Pure component, the
/// state (selected type) lives in LibraryView. Only shown when at least two
/// types are available.
struct MediaTabBar: View {
    let types: [MediaType]
    let selected: MediaType
    /// Direct callback instead of a binding — the switch has side effects
    /// (resetting the navigation path) that were unreliable in a binding setter
    /// (a tap "did nothing").
    let onSelect: (MediaType) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(types) { type in
                Button {
                    onSelect(type)
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
