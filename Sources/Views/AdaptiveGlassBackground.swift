import SwiftUI

/// Glas-Optik für schwebende Elemente (Mini-Player, Such-Button).
/// Nutzt Apples echtes `.glassEffect()` (iOS 26) wo verfügbar — `.clear` mit
/// einer kräftigen schwarzen Tönung (0.7 Opazität): dunkelt genug ab, um
/// über unruhigem Hintergrund (Cover-Bilder) lesbar zu bleiben, ohne die
/// hellere/durchsichtigere Grundoptik von `.clear` ganz zu verlieren.
///
/// Auf älteren iOS-Versionen (unterhalb iOS 26) fällt es auf ein manuell
/// aufgehelltes `.ultraThinMaterial` zurück, damit die App weiterhin überall
/// baut und läuft.
///
/// Geteilt zwischen Mini-Player und Such-Button, damit beide optisch
/// zusammenpassen.
struct AdaptiveGlassBackground<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear.tint(Color.black.opacity(0.7)), in: shape)
        } else {
            content
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(shape.fill(Color.white.opacity(0.08)))
                }
                .overlay(shape.stroke(Color.white.opacity(0.2), lineWidth: 0.5))
        }
    }
}
