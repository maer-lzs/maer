import SwiftUI

/// Floating magnifier button at the bottom — modeled on the separate, floating
/// search button Apple uses since iOS 26 in Music & co. Opens the full-screen
/// `SearchOverlay` (glass sheet with real-time search) instead of expanding into
/// a field itself.
struct FloatingSearchButton: View {
    let action: () -> Void
    /// X17: reduce the glass in lock-step with the other bottom-bar elements
    /// (shared BottomBarState.isScrolling) so the row never mixes clear glass and
    /// the reduced material.
    var reduced: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(AdaptiveGlassBackground(shape: Circle(), reduced: reduced))
        .accessibilityLabel(Text("Search"))
    }
}
