import SwiftUI

/// Schwebender Lupen-Button unten — angelehnt an den separaten, schwebenden
/// Such-Button, den Apple seit iOS 26 in Music & Co. nutzt. Öffnet das
/// vollflächige `SearchOverlay` (Glas-Sheet mit Echtzeit-Suche), statt sich
/// selbst zu einem Feld aufzuklappen.
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
