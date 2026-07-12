import SwiftUI

/// Zeigt die aktuell im PlayerCoordinator laufende Session als vollen
/// Player screen. Loads nothing itself anymore — the coordinator handles
/// loading so the same session stays visible from the mini-player bar too.
struct PlayerScreen: View {
    @ObservedObject var coordinator: PlayerCoordinator
    /// Passed through from the overlay presentation (drag-to-dismiss).
    var dragProgress: CGFloat = 0
    /// Eck-Radius des Overlay-Sheets — wird an PlayerView durchgereicht.
    var cornerRadius: CGFloat = 0
    /// Explizite Safe-Area-Insets (Root ignoriert Safe Areas).
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    var body: some View {
        Group {
            if let viewModel = coordinator.viewModel, let item = coordinator.activeItem {
                PlayerView(
                    viewModel: viewModel,
                    coverURL: AppSession.shared.coverURL(forItemId: item.id),
                    dragProgress: dragProgress,
                    cornerRadius: cornerRadius,
                    topInset: topInset,
                    bottomInset: bottomInset
                )
            } else if coordinator.isLoading {
                ProgressView("Loading…")
            } else if let error = coordinator.loadError {
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ProgressView()
            }
        }
        .navigationTitle(coordinator.activeItem?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}
