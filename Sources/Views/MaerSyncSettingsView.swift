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
    /// The one switch above every carrier. It lives on the settings page,
    /// and until now this page said nothing about it: one could sign in,
    /// read "Signed in as …" and nothing travelled, because the switch was
    /// off. A promise a second surface silently withdraws.
    @AppStorage(AppStorageKeys.podcastICloudSync) private var syncAcrossDevices = true
    /// Whether everything that was handed out really travels the service,
    /// not what is set up here. The carriers are chosen once each, at
    /// different moments, so the two can disagree. Read from the register
    /// the factories write: asking a runner would CREATE it, with the
    /// access of that moment, and the question would make its own answer
    /// true.
    @State private var carrierIsTheService = false

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

                // Signed in is not the same as travelling. The one switch
                // above every carrier can be off, and then this page was
                // showing a working sign-in over a service that carries
                // nothing. It is named here in both states, not only in
                // the bad one: a state that appears only when it is wrong
                // teaches nobody where the switch lives.
                switch MaerSyncStanding.standing(syncAcrossDevices: syncAcrossDevices,
                                                 carrierIsTheService: carrierIsTheService) {
                case .carrying:
                    Label {
                        Text("Sync across devices is on, so what is set up here is in use.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityIdentifier("maer-sync-switch-on")
                case .fromTheNextStart:
                    // The setting is right and the operation has not caught
                    // up: the runners choose their carrier once, at start.
                    // Saying "in use" here would confirm an arrangement
                    // that carries nothing yet.
                    Label {
                        Text("Set up. Your data travels over this service from the next app start.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("maer-sync-next-start")
                case .switchedOff:
                    Label {
                        Text("Sync across devices is off, so nothing travels yet. The switch is in Settings, under Sync.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("maer-sync-switch-off")
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
        .onAppear {
            refusal = MaerSyncCarriers.session.lastRefusal
            carrierIsTheService = CarrierChoices.allTravelTheService
        }
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
