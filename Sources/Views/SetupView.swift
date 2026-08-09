// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

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
                        .textContentType(.URL)   // F7: password-manager AutoFill
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

                // F10: the EQUAL second path — no server required. Podcasts
                // work immediately; every server source (Audiobookshelf,
                // music, gpodder) attaches later in the settings.
                Section {
                    Button {
                        AppStorageKeys.serverlessModeValue = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Start without a server")
                            Spacer()
                        }
                    }
                    // Locale-independent handle for the UI-test harness.
                    .accessibilityIdentifier("start-serverless")
                } footer: {
                    Text("Listen to podcasts right away — no account needed. Audiobookshelf, a music server or podcast sync can be added anytime in Settings. Connecting to a server on your home network may ask for local-network permission.")
                }
            }
            // F10 rest: the FIRST screen must not be branded as an ABS login
            // — Mär does not begin behind an ABS server (serverless path is a
            // first-class option below).
            .navigationTitle(Text(verbatim: "Mär"))
        }
    }
}
