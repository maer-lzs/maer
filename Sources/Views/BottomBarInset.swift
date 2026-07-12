import SwiftUI

/// Height of the floating bottom zone (mini-player + tab bar), which sits as an
/// overlay above everything and therefore reserves NO space. Every scroll
/// content (library, podcasts, detail pages) keeps this much free at the bottom
/// so the last covers don't disappear under the mini-player.
private struct BottomBarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var bottomBarInset: CGFloat {
        get { self[BottomBarInsetKey.self] }
        set { self[BottomBarInsetKey.self] = newValue }
    }
}

extension View {
    /// Leave as much space at the bottom as the floating bottom zone is tall.
    func bottomBarClearance() -> some View {
        modifier(BottomBarClearance())
    }
}

private struct BottomBarClearance: ViewModifier {
    @Environment(\.bottomBarInset) private var inset
    func body(content: Content) -> some View {
        content.padding(.bottom, inset)
    }
}
