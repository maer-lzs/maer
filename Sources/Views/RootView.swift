import SwiftUI

struct RootView: View {
    /// Process-wide session (see AppSession): the same instances are also used
    /// by the CarPlay scene.
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
