import SwiftUI

/// Globale, transiente Glas-Pille (Icon + kurzer Text), die anzeigt, woher der
/// aktuelle Stand stammt bzw. wie er gesichert ist. Wird EINMAL zentral als
/// Overlay im NavigationStack der Bibliothek gehostet und erscheint damit auf
/// jeder Ebene (Bibliothek, Buchdetail, voller Player).
///
/// Its own view with `@ObservedObject` so changes to `sourceHint` arrive
/// reliably — a value read only via `coordinator.viewModel?.sourceHint` would
/// not update, since `PlayerCoordinator` only notifies when `viewModel` is
/// completely re-SET, not when values WITHIN it change (the same pattern as the
/// play/pause button).
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
                    // Purely informational — must never intercept the sort menu,
                    // sign-out, search button, mini-player or player controls.
                    .allowsHitTesting(false)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.5), value: viewModel.sourceHint)
    }
}
