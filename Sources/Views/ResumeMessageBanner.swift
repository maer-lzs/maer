import SwiftUI

/// Globale, transiente Glas-Pille (Icon + kurzer Text), die anzeigt, woher der
/// aktuelle Stand stammt bzw. wie er gesichert ist. Wird EINMAL zentral als
/// Overlay im NavigationStack der Bibliothek gehostet und erscheint damit auf
/// jeder Ebene (Bibliothek, Buchdetail, voller Player).
///
/// Eigene View mit `@ObservedObject`, damit Änderungen an `sourceHint`
/// zuverlässig ankommen — ein nur über `coordinator.viewModel?.sourceHint`
/// gelesener Wert würde nicht aktualisieren, da `PlayerCoordinator` nur
/// benachrichtigt, wenn `viewModel` komplett neu GESETZT wird, nicht wenn sich
/// Werte DARIN ändern (dasselbe Muster wie beim Play/Pause-Button).
struct ResumeMessageBanner: View {
    @ObservedObject var viewModel: PlayerViewModel

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        Group {
            if let hint = viewModel.sourceHint {
                Label(hint.label, systemImage: hint.icon)
                    .font(.subheadline).bold()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .modifier(AdaptiveGlassBackground(shape: shape))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    // Rein informativ — darf Sortier-Menü, Abmelden, Such-Button,
                    // Mini-Player oder Player-Steuerung nie abfangen.
                    .allowsHitTesting(false)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.5), value: viewModel.sourceHint)
    }
}
