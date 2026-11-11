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
                CredentialField.serverURL("Server URL", text: $serverURL,
                                          id: "jellyfin-url",
                                          service: .jellyfin)
                CredentialField.username("Username", text: $username,
                                         id: "jellyfin-username")
                CredentialField.secret("Password", text: $password,
                                       id: "jellyfin-password")
            } header: {
                Text("Jellyfin Server")
            } footer: {
                Text("Example: https://jellyfin.example.com. Sign-in stores an access token in the keychain.")
            }

            CustomHeadersSection(address: serverURL, idPrefix: "jellyfin")

            Section {
                AppSwitch("Use as music source", isOn: $enabled)
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
                        // A press gets the answer of now, even during the
                        // rest after a refused connection.
                        var err = await LookupOccasion.deliberate { await JellyfinProvider.shared.testConnection() }
                        // Only a WORKING address is remembered.
                        if err == nil { KnownServers.remember(serverURL, service: .jellyfin) }
                        if let failure = err { err = await AccessGuard.sentence(after: failure, address: serverURL) }
                        setStatus(err ?? String(localized: "Connected."), isError: err != nil)
                        isTesting = false
                    }
                } label: {
                    Label("Test connection", systemImage: "bolt.horizontal")
                }
                .disabled(isTesting || !SourceReadiness.fieldsFilled(address: serverURL, username: username))

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
                .disabled(isTesting || !SourceReadiness.fieldsFilled(address: serverURL, username: username))

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
        // Prefill the LAST stored state; a transiently empty
        // field must never erase a stored value.
        .onAppear {
            if serverURL.isEmpty { serverURL = AppStorageKeys.jellyfinServerURLValue }
            if username.isEmpty { username = AppStorageKeys.jellyfinUsernameValue }
            if password.isEmpty { password = AppStorageKeys.jellyfinPasswordValue }
        }
    }

    private func save() {
        // Empty fields leave the stored values alone. Clearing
        // a source is done via the toggle, not by emptying a field.
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespaces)
        if !trimmedURL.isEmpty {
            // The access the stored server handed out, and its password,
            // go to no other one.
            password = JellyfinProvider.passwordAfterAddress(trimmedURL, typed: password)
            JellyfinProvider.forgetAccessOnSwitch(to: trimmedURL)
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
