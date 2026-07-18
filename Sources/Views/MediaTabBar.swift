import SwiftUI

/// Glass tab bar at the bottom (below the mini-player) for the content types —
/// audiobooks/podcasts/music/radio. Its own glass element in the same language
/// as mini-player and pill. A capsule slides behind the SELECTED tab (N1: the
/// primary "where am I" anchor, matchedGeometry), and the selected label carries
/// its media type's tint (Audible orange / Podcasts purple / Music red, Home
/// neutral — see MediaType.tint). Pure component, the state (selected type)
/// lives in LibraryView. Only shown when at least two types are available.
struct MediaTabBar: View {
    let types: [MediaType]
    let selected: MediaType
    /// Direct callback instead of a binding — the switch has side effects
    /// (resetting the navigation path) that were unreliable in a binding setter
    /// (a tap "did nothing").
    let onSelect: (MediaType) -> Void

    /// D7/B6: at accessibility sizes the caption labels truncated anyway —
    /// icons only, the label lives on as the accessibility label.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// N1: shared namespace so the active pill glides between tabs.
    @Namespace private var pillNS

    var body: some View {
        HStack(spacing: 4) {
            ForEach(types) { type in
                Button {
                    onSelect(type)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: type.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text(type.label)
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    // Selected → the type's own tint; unselected → neutral. The
                    // colour appears only on the active selector, never always.
                    .foregroundStyle(selected == type ? type.tint : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        // N1/N1b/N1c: the sliding pill behind the active tab — a
                        // wash of the type tint (neutral at Home), no glass
                        // (backward-compatible). matchedGeometry glides the single
                        // instance on a tab switch. Capsule (proportional
                        // rounding — a fixed corner radius read as a box); inset
                        // vertically so it does NOT fill the full bar height.
                        if selected == type {
                            Capsule()
                                .fill(type.tint.opacity(0.16))
                                .matchedGeometryEffect(id: "activeTabPill", in: pillNS)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 4)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(type.label))
                // Locale-independent handle for the UI-test harness.
                .accessibilityIdentifier("tab-\(type.rawValue)")
            }
        }
        .animation(.snappy(duration: 0.3), value: selected)
        .padding(.horizontal, 6)
        .modifier(AdaptiveGlassBackground(shape: Capsule()))
    }
}
