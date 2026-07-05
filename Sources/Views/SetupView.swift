import SwiftUI

struct SetupView: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("z. B. audio.example.com", text: $viewModel.serverURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Server")
                }

                Section {
                    SecureField("API-Token", text: $viewModel.apiToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API-Token")
                } footer: {
                    Text("Zu finden in der Audiobookshelf-Weboberfläche unter Einstellungen → Benutzer → eigenen Account öffnen (oder Einstellungen → API-Keys bei neueren Versionen).")
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
                                Text("Verbinden")
                            }
                            Spacer()
                        }
                    }
                    .disabled(viewModel.isLoading || viewModel.serverURLString.isEmpty || viewModel.apiToken.isEmpty)
                }
            }
            .navigationTitle("Audiobookshelf")
        }
    }
}
