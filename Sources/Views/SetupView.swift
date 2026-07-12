import SwiftUI

/// Demo access for the app review (Apple requires a testable account for
/// server-bound apps). Fill in with a hosted demo server before submitting; as
/// long as both values are nil, none of it appears in the app.
enum DemoAccess {
    static let serverURL: String? = nil
    static let apiToken: String? = nil

    static var isAvailable: Bool { serverURL != nil && apiToken != nil }
}

struct SetupView: View {
    @ObservedObject var viewModel: AuthViewModel

    private var hasCredentials: Bool {
        switch viewModel.loginMode {
        case .password: return !viewModel.username.isEmpty && !viewModel.password.isEmpty
        case .token: return !viewModel.apiToken.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. audio.example.com", text: $viewModel.serverURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Server")
                }

                Section {
                    Picker("Sign-in method", selection: $viewModel.loginMode) {
                        Text("Password").tag(AuthViewModel.LoginMode.password)
                        Text("API Token").tag(AuthViewModel.LoginMode.token)
                    }
                    .pickerStyle(.segmented)

                    switch viewModel.loginMode {
                    case .password:
                        TextField("Username", text: $viewModel.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                        SecureField("Password", text: $viewModel.password)
                            .textContentType(.password)
                    case .token:
                        SecureField("API Token", text: $viewModel.apiToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Sign In")
                } footer: {
                    if viewModel.loginMode == .token {
                        Text("Found in the Audiobookshelf web interface under Settings → Users → open your account (or Settings → API Keys on newer versions).")
                    } else {
                        Text("Your Audiobookshelf account credentials. On servers with the new token system, playback may sign out when the token expires — use an API key there instead.")
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isLoading {
                                ProgressView()
                            } else {
                                Text("Connect")
                            }
                            Spacer()
                        }
                    }
                    .disabled(viewModel.isLoading || viewModel.serverURLString.isEmpty || !hasCredentials)
                }

                if DemoAccess.isAvailable {
                    Section {
                        Button("Use Demo Server") {
                            viewModel.serverURLString = DemoAccess.serverURL ?? ""
                            viewModel.loginMode = .token
                            viewModel.apiToken = DemoAccess.apiToken ?? ""
                            Task { await viewModel.connect() }
                        }
                    } footer: {
                        Text("Connects to a public demo server with sample audiobooks.")
                    }
                }
            }
            .navigationTitle("Audiobookshelf")
        }
    }
}
