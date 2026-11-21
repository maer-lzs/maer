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
    /// The server at the typed address answered that it offers Quick Connect.
    @State private var quickConnectOffered = false
    /// The code shown while a Quick Connect sign-in waits for approval.
    @State private var quickConnectCode: String?
    @State private var quickConnectTask: Task<Void, Never>?

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

            if quickConnectOffered {
                Section {
                    if let quickConnectCode {
                        Text(verbatim: quickConnectCode)
                            .font(.largeTitle.monospacedDigit().weight(.semibold))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("jellyfin-quick-connect-code")
                        Text("In Jellyfin, where you are signed in, open Quick Connect and enter this code.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) { quickConnectTask?.cancel() }
                    } else {
                        Button {
                            startQuickConnect()
                        } label: {
                            Label("Sign in with Quick Connect", systemImage: "qrcode")
                        }
                        .disabled(isTesting)
                        .accessibilityIdentifier("jellyfin-quick-connect")
                    }
                } footer: {
                    Text("Quick Connect signs in without a password, through a Jellyfin session where you are already signed in.")
                }
            }

            CustomHeadersSection(address: serverURL, idPrefix: "jellyfin")

            Section {
                AppSwitch("Use as music source", isOn: $enabled)
                    // Locale-independent handle for the UI-test harness.
                    .accessibilityIdentifier("jellyfin-source-toggle")
                    .onChange(of: enabled) { _, _ in save() }
            } footer: {
                Text("When on, your Jellyfin albums, artists and playlists appear in the Music tab.")
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
                    LocalNetworkSettingsButton(message: statusMessage)
                }
            }
        }
        .navigationTitle("Jellyfin")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .onDisappear {
            quickConnectTask?.cancel()
            save()
        }
        // Asked again for each typed address, once typing rests.
        .task(id: serverURL) {
            do { try await JellyfinQuickConnect.restBeforeAsking() } catch { return }
            let address = serverURL.trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty else { quickConnectOffered = false; return }
            quickConnectOffered = await JellyfinProvider.quickConnectClient(address: address).quickConnectOffered()
        }
        // Prefill the LAST stored state; a transiently empty
        // field must never erase a stored value.
        .onAppear {
            if serverURL.isEmpty { serverURL = AppStorageKeys.jellyfinServerURLValue }
            if username.isEmpty { username = AppStorageKeys.jellyfinUsernameValue }
            if password.isEmpty { password = AppStorageKeys.jellyfinPasswordValue }
        }
    }

    private func save() {
        password = Self.keep(serverURL: serverURL, username: username, password: password)
        AppStorageKeys.jellyfinEnabledValue = enabled
        JellyfinProvider.shared.reloadConfig()
    }

    /// The one way an account is stored, from the fields and from Quick
    /// Connect. Empty fields leave the stored values alone; clearing a
    /// source is done via the toggle, not by emptying a field. Answers the
    /// password that stays.
    @discardableResult
    static func keep(serverURL: String, username: String, password: String) -> String {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespaces)
        // Another user is another account: its access and what the
        // stored account wrote go the way of another address.
        let typedUser = username.trimmingCharacters(in: .whitespaces)
        let newUser = typedUser.isEmpty ? AppStorageKeys.jellyfinUsernameValue : typedUser
        // Asked with the stored address when the field is empty: another
        // user at the stored server is another account too. The access the
        // stored account was handed out, and its password, go to no other.
        let address = trimmedURL.isEmpty ? AppStorageKeys.jellyfinServerURLValue : trimmedURL
        var password = password
        password = JellyfinProvider.passwordAfterAddress(address, user: newUser, typed: password)
        JellyfinProvider.forgetAccessOnSwitch(to: address, user: newUser)
        if !trimmedURL.isEmpty { AppStorageKeys.jellyfinServerURLValue = trimmedURL }
        let trimmedUser = typedUser
        if !trimmedUser.isEmpty {
            AppStorageKeys.jellyfinUsernameValue = trimmedUser
        }
        if !password.isEmpty {
            AppStorageKeys.setJellyfinPassword(password)
        }
        return password
    }

    /// Shows a code and waits for its approval; the page keeps the account
    /// once it is approved. A cancel says nothing.
    private func startQuickConnect() {
        let address = serverURL.trimmingCharacters(in: .whitespaces)
        let client = JellyfinProvider.quickConnectClient(address: address)
        statusMessage = nil
        quickConnectTask = Task {
            defer { quickConnectCode = nil; quickConnectTask = nil }
            let start: (secret: String, code: String)
            do {
                start = try await client.quickConnectStart()
            } catch {
                setStatus(ErrorSentence.of(error), isError: true)
                return
            }
            quickConnectCode = start.code
            let outcome = await JellyfinQuickConnect.run(
                look: { await client.quickConnectAnswer(secret: start.secret) },
                finish: {
                    await JellyfinProvider.finishQuickConnect(client: client, secret: start.secret) { user in
                        Self.keep(serverURL: address, username: user, password: "")
                    }
                },
                wait: { try await JellyfinQuickConnect.waitBetweenLooks() })
            if outcome == .signedIn {
                username = AppStorageKeys.jellyfinUsernameValue
                password = ""
                KnownServers.remember(address, service: .jellyfin)
                setStatus(String(localized: "Connected."), isError: false)
            } else if let sentence = outcome.sentence {
                setStatus(sentence, isError: true)
            }
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
