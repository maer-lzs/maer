import SwiftUI

struct RootView: View {
    /// Prozessweite Session (siehe AppSession): dieselben Instanzen werden
    /// auch von der CarPlay-Szene verwendet.
    @ObservedObject private var authViewModel = AppSession.shared.authViewModel

    var body: some View {
        Group {
            if authViewModel.isLoggedIn {
                LibraryView(provider: authViewModel.apiClient, onLogout: authViewModel.logout)
            } else {
                SetupView(viewModel: authViewModel)
            }
        }
    }
}
