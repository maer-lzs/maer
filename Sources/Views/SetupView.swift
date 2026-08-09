// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The first screen is the EXPLANATION, not a slideshow: one sentence about
/// what Mär is, then the map of areas with one line each about what it needs.
/// What you tap away you have not read — so there is nothing to tap away.
///
/// It used to be an Audiobookshelf login with an emergency exit, and the exit
/// advertised podcasts only, although four of five areas run without any
/// account. Now "start without a server" is the equal choice, and the ABS
/// help texts live where they belong: behind "Audiobooks".
struct SetupView: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Mär is a home for audiobooks, music, podcasts, radio and free catalogs — your own servers and the open net in one app.")
                        .font(.callout)
                }

                SourceMapCard(facts: .current) { area in
                    AnyView(SourceAreaPage(area: area, absDestination: {
                        AnyView(ABSLoginPage(viewModel: viewModel))
                    }))
                }

                // The EQUAL second path — no server required, and it names
                // what it actually gets: not podcasts alone.
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
                    Text("Radio, podcasts and the free catalogs are there right away — no account needed. Audiobookshelf, a music server or podcast sync can be added anytime in Settings. Connecting to a server on your home network may ask for local-network permission.")
                }
            }
            // The FIRST screen must not be branded as an ABS login — Mär does
            // not begin behind an ABS server.
            .navigationTitle(Text(verbatim: "Mär"))
        }
    }
}

/// The Audiobookshelf login — the ONE form for it, behind "Audiobooks" during
/// the first run and behind "Connect" in the settings. The ABS-specific help
/// (web interface, API keys, token expiry) sits with it, not on a screen that
/// is supposed to explain the whole app.
struct ABSLoginForm: View {
    @ObservedObject var viewModel: AuthViewModel

    private var hasCredentials: Bool {
        switch viewModel.loginMode {
        case .password: return !viewModel.username.isEmpty && !viewModel.password.isEmpty
        case .token: return !viewModel.apiToken.isEmpty
        }
    }

    var body: some View {
        Group {
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
                .accessibilityIdentifier("abs-connect")
            }
        }
    }
}

/// The login form as a page — pushed from the map during the first run and
/// presented from the source page later.
struct ABSLoginPage: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        Form { ABSLoginForm(viewModel: viewModel) }
            .navigationTitle(Text(verbatim: "Audiobookshelf"))
            .navigationBarTitleDisplayMode(.inline)
    }
}
