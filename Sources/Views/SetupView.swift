import SwiftUI

/// Demo-Zugang für den App-Review (Apple verlangt bei Server-gebundenen Apps
/// einen testbaren Zugang). Vor dem Einreichen mit einem gehosteten
/// Demo-Server befüllen; solange beide Werte nil sind, erscheint in der App
/// nichts davon.
enum DemoAccess {
    static let serverURL: String? = nil
    static let apiToken: String? = nil

    static var isAvailable: Bool { serverURL != nil && apiToken != nil }
}

struct SetupView: View {
    @ObservedObject var viewModel: AuthViewModel

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
                    SecureField("API Token", text: $viewModel.apiToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API Token")
                } footer: {
                    Text("Found in the Audiobookshelf web interface under Settings → Users → open your account (or Settings → API Keys on newer versions).")
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
                    .disabled(viewModel.isLoading || viewModel.serverURLString.isEmpty || viewModel.apiToken.isEmpty)
                }

                if DemoAccess.isAvailable {
                    Section {
                        Button("Use Demo Server") {
                            viewModel.serverURLString = DemoAccess.serverURL ?? ""
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
