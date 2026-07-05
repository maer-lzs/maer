import SwiftUI

struct RootView: View {
    @StateObject private var authViewModel = AuthViewModel()

    var body: some View {
        Group {
            if authViewModel.isLoggedIn {
                LibraryView(apiClient: authViewModel.apiClient, onLogout: authViewModel.logout)
            } else {
                SetupView(viewModel: authViewModel)
            }
        }
    }
}
