// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The Mär sync service the person hosts: address, account, password. A
/// sign-in trades the password for a token this device keeps in the
/// keychain; the password itself is kept nowhere. The pot and the
/// playback claim run over the service from the next start, because the
/// carrier factories choose at start-up and the runners keep what they
/// were given. A write the service refused is shown here with the
/// service's own sentence: it is the one failure that must not stay
/// silent, and the queue waits behind it.
struct MaerSyncSettingsView: View {
    @State private var serverURL = AppStorageKeys.maerSyncURLValue
    @State private var owner = AppStorageKeys.maerSyncOwnerValue
    @State private var secret = ""
    @State private var signedIn = !AppStorageKeys.maerSyncTokenValue.isEmpty
    @State private var refusal = MaerSyncCarriers.session.lastRefusal

    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        Form {
            Section {
                CredentialField.serverURL("Server URL", text: $serverURL, id: "maer-sync-url")
                CredentialField.username("Account", text: $owner, id: "maer-sync-account")
                CredentialField.secret("Password", text: $secret, id: "maer-sync-password")
            } header: {
                Text("Mär Sync Service")
            } footer: {
                Text("Example: https://sync.example.com. Signing in trades the password for a token this device keeps in the keychain; the password itself is not kept.")
            }

            Section {
                if signedIn {
                    Label {
                        Text("Signed in as \(owner).")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                    .accessibilityIdentifier("maer-sync-signed-in")
                } else {
                    Label {
                        Text("Not signed in.")
                    } icon: {
                        Image(systemName: "circle.dashed")
                    }
                    .accessibilityIdentifier("maer-sync-signed-out")
                }

                Button {
                    test()
                } label: {
                    Label("Test connection", systemImage: "bolt.horizontal")
                }
                .disabled(isWorking || serverURL.isEmpty)

                Button {
                    signIn()
                } label: {
                    Label("Sign in", systemImage: "person.badge.key")
                }
                .disabled(isWorking || serverURL.isEmpty || owner.isEmpty || secret.isEmpty)

                if signedIn {
                    Button(role: .destructive) {
                        signOut()
                    } label: {
                        Label("Sign out", systemImage: "person.badge.minus")
                    }
                    .disabled(isWorking)
                }

                if isWorking {
                    HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) }
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
            } footer: {
                Text("Podcast progress, the playback claim, the listening statistics, the playlists and your choices, from sorts to favorites, run over this service from the next start.")
            }

            if let refusal {
                Section {
                    Label {
                        Text("The service refused a write on \(refusal.at.formatted(date: .abbreviated, time: .shortened)): \(refusal.reason)")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("maer-sync-refusal")
                } footer: {
                    Text("Nothing was lost: the device keeps what it wrote and tries again at the next occasion. A pot that shrank or a format the service holds newer is not something this device decides on its own.")
                }
            }
        }
        .navigationTitle("Mär Sync")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .onAppear { refusal = MaerSyncCarriers.session.lastRefusal }
    }

    private func test() {
        isWorking = true
        Task {
            defer { isWorking = false }
            switch await MaerSyncSignIn.test(address: serverURL) {
            case .reached:
                setStatus(String(localized: "Connected."), isError: false)
            case .badAddress:
                setStatus(String(localized: "The address is not a web address."), isError: true)
            case .blockedHere:
                // The same sentence the sign-in gives for the same answer,
                // so the two buttons cannot tell two stories about one 403.
                setStatus(String(localized: "The service is not reachable from this network."), isError: true)
            case .silent:
                setStatus(String(localized: "The service did not answer."), isError: true)
            }
        }
    }

    private func signIn() {
        isWorking = true
        Task {
            defer { isWorking = false }
            switch await MaerSyncSignIn.perform(address: serverURL, owner: owner, secret: secret) {
            case .signedIn(let access, let account):
                MaerSyncSignIn.store(access, owner: account)
                serverURL = access.baseURL.absoluteString
                owner = account
                secret = ""
                signedIn = true
                setStatus(String(localized: "Signed in."), isError: false)
            case .missing:
                setStatus(String(localized: "Please fill in every field."), isError: true)
            case .badAddress:
                setStatus(String(localized: "The address is not a web address."), isError: true)
            case .refused:
                setStatus(String(localized: "The service refused the sign-in."), isError: true)
            case .blockedHere:
                setStatus(String(localized: "The service is not reachable from this network."), isError: true)
            case .unreachable:
                setStatus(String(localized: "The service did not answer."), isError: true)
            }
        }
    }

    private func signOut() {
        MaerSyncSignIn.signOut()
        signedIn = false
        setStatus(String(localized: "Signed out."), isError: false)
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
