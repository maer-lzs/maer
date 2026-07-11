import SwiftUI

/// Höhe der schwebenden Bottom-Zone (Mini-Player + Tab-Leiste), die als
/// Overlay über allem liegt und deshalb KEINEN Platz reserviert. Jeder
/// Scroll-Inhalt (Bibliothek, Podcasts, Detailseiten) hält unten so viel
/// frei, damit die letzten Cover nicht unter dem Mini-Player verschwinden.
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
    /// Unten so viel Platz lassen, wie die schwebende Bottom-Zone hoch ist.
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
