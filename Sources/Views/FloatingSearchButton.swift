import SwiftUI

/// Schwebender Lupen-Button unten — angelehnt an den separaten, schwebenden
/// Search button as Apple uses it since iOS 26 in Music & co. Opens the
/// full-screen `SearchOverlay` (glass sheet with real-time search) instead of
/// expanding into a field itself.
struct FloatingSearchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(AdaptiveGlassBackground(shape: Circle()))
        .accessibilityLabel(Text("Search"))
    }
}
