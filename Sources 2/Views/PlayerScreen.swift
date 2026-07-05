import SwiftUI

/// Zeigt die aktuell im PlayerCoordinator laufende Session als vollen
/// Player-Screen. Lädt selbst nichts mehr — das Laden übernimmt der
/// Coordinator, damit dieselbe Session auch von der Mini-Player-Leiste aus
/// sichtbar bleibt.
struct PlayerScreen: View {
    @ObservedObject var coordinator: PlayerCoordinator

    var body: some View {
        Group {
            if let viewModel = coordinator.viewModel, let item = coordinator.activeItem {
                PlayerView(
                    viewModel: viewModel,
                    coverURL: coordinator.apiClient.coverURL(forItemId: item.id)
                )
            } else if coordinator.isLoading {
                ProgressView("Wird geladen…")
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
