// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Configure a Jellyfin server as the music source (Etappe 2). Same pattern
/// as the Subsonic source page: server/user/password, test the connection,
/// switch it on. Sign-in exchanges the password for an access token that is
/// stored in the keychain (with the password, for silent re-auth).
struct JellyfinSourceView: View {
    @State private var serverURL = AppStorageKeys.jellyfinServerURLValue
    @State private var username = AppStorageKeys.jellyfinUsernameValue
    @State private var password = AppStorageKeys.jellyfinPasswordValue
    @State private var enabled = AppStorageKeys.jellyfinEnabledValue

    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Jellyfin Server")
            } footer: {
                Text("Example: https://jellyfin.example.com — sign-in stores an access token in the keychain.")
            }

            Section {
                Toggle("Use as music source", isOn: $enabled)
                    // Locale-independent handle for the UI-test harness.
                    .accessibilityIdentifier("jellyfin-source-toggle")
                    .onChange(of: enabled) { _, _ in save() }
            } footer: {
                Text("When on (and Subsonic off), your Jellyfin albums, artists and playlists appear in the Music tab.")
            }

            Section {
                Button {
                    save()
                    isTesting = true
                    Task {
                        let err = await JellyfinProvider.shared.testConnection()
                        setStatus(err ?? String(localized: "Connected."), isError: err != nil)
                        isTesting = false
                    }
                } label: {
                    Label("Test connection", systemImage: "bolt.horizontal")
                }
                .disabled(isTesting || serverURL.isEmpty || username.isEmpty)

                Button {
                    save()
                    isTesting = true
                    Task {
                        let err = await JellyfinProvider.shared.syncLibraryNow()
                        setStatus(err ?? String(localized: "Music library synced."), isError: err != nil)
                        isTesting = false
                    }
                } label: {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                }
                .disabled(isTesting || serverURL.isEmpty || username.isEmpty)

                if isTesting {
                    HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) }
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
            }
        }
        .navigationTitle("Jellyfin")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .onDisappear { save() }
        // Y26 pattern: prefill the LAST stored state; a transiently empty
        // field must never erase a stored value.
        .onAppear {
            if serverURL.isEmpty { serverURL = AppStorageKeys.jellyfinServerURLValue }
            if username.isEmpty { username = AppStorageKeys.jellyfinUsernameValue }
            if password.isEmpty { password = AppStorageKeys.jellyfinPasswordValue }
        }
    }

    private func save() {
        // Y26/Y38 class: empty fields leave the stored values alone — clearing
        // a source is done via the toggle, not by emptying a field.
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespaces)
        if !trimmedURL.isEmpty {
            AppStorageKeys.jellyfinServerURLValue = trimmedURL
        }
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        if !trimmedUser.isEmpty {
            AppStorageKeys.jellyfinUsernameValue = trimmedUser
        }
        if !password.isEmpty {
            AppStorageKeys.setJellyfinPassword(password)
        }
        AppStorageKeys.jellyfinEnabledValue = enabled
        JellyfinProvider.shared.reloadConfig()
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
