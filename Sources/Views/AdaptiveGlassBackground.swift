import SwiftUI

/// Glas-Optik für schwebende Elemente (Mini-Player, Such-Button).
/// Nutzt Apples echtes `.glassEffect()` (iOS 26) wo verfügbar — die
/// `.regular`-Variante (mehr Weichzeichnung, weniger rohe
/// Verzerrung/Refraktion als `.clear`, dadurch deutlich lesbarer über
/// unruhigem Hintergrund wie Cover-Bildern), mit einem ganz leichten weißen
/// Hauch obendrauf.
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
                        .overlay(shape.fill(Color.white.opacity(0.05)))
                }
                .overlay(shape.stroke(Color.white.opacity(0.2), lineWidth: 0.5))
        }
    }
}
