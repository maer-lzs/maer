// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The first screen is the EXPLANATION, not a slideshow: one sentence about
/// what Mär is, then the map of areas with one line each about what it needs.
/// What you tap away you have not read. So there is nothing to tap away.
///
/// "Start without a server" is the equal choice beside the map, so it stands
/// in a bar pinned to the bottom edge: visible without scrolling on every
/// phone size and text size, however many rows the map carries. The ABS help
/// texts live behind "Audiobooks".
struct SetupView: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Mär is a home for audiobooks, music, podcasts, radio and free catalogs: your own servers and the open net in one app.")
                        .font(.callout)
                }

                SourceMapCard(facts: .current) { area in
                    AnyView(SourceAreaPage(area: area, absDestination: {
                        AnyView(ABSLoginPage(viewModel: viewModel))
                    }))
                }

                // What the pinned button gets, named in full: not podcasts alone.
                Section {} footer: {
                    Text("Radio, podcasts and the free catalogs are there right away, no account needed. Audiobookshelf, a music server or podcast sync can be added anytime in Settings. Connecting to a server on your home network may ask for local-network permission.")
                }
            }
            // The FIRST screen must not be branded as an ABS login. Mär does
            // not begin behind an ABS server.
            .navigationTitle(Text(verbatim: "Mär"))
            // The EQUAL second path. A row at the end of the form slides below
            // the fold as soon as the map grows, and a lazy form does not even
            // build it there; the bar keeps it on the first screen.
            .pinnedToBottom {
                Button {
                    AppStorageKeys.serverlessModeValue = true
                } label: {
                    Text("Start without a server")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 8)
                // Locale-independent handle for the UI-test harness.
                .accessibilityIdentifier("start-serverless")
            }
        }
    }
}

private extension View {
    /// A bar at the bottom edge that the content scrolls behind. The bar
    /// with its scroll edge exists from iOS 26; below it the inset keeps the
    /// same place without the edge.
    @ViewBuilder
    func pinnedToBottom<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, content: bar)
        } else {
            safeAreaInset(edge: .bottom, content: bar)
        }
    }
}

/// The Audiobookshelf login. The ONE form for it, behind "Audiobooks" during
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
                CredentialField.serverURL("e.g. audio.example.com",
                                          text: $viewModel.serverURLString,
                                          id: "setup-url",
                                          service: .audiobookshelf)
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
                    CredentialField.username("Username", text: $viewModel.username,
                                             id: "setup-username")
                    CredentialField.secret("Password", text: $viewModel.password,
                                           id: "setup-password")
                case .token:
                    CredentialField.secret("API Token", text: $viewModel.apiToken,
                                           id: "setup-token")
                }
            } header: {
                Text("Sign In")
            } footer: {
                if viewModel.loginMode == .token {
                    Text("Found in the Audiobookshelf web interface under Settings → Users → open your account (or Settings → API Keys on newer versions).")
                } else {
                    Text("Your Audiobookshelf account credentials. On servers with the new token system, playback may sign out when the token expires. Use an API key there instead.")
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

/// The login form as a page. Pushed from the map during the first run and
/// presented from the source page later.
struct ABSLoginPage: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        Form { ABSLoginForm(viewModel: viewModel) }
            .navigationTitle(Text(verbatim: "Audiobookshelf"))
            .navigationBarTitleDisplayMode(.inline)
    }
}
