// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit

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
    /// The new password, typed twice, and whether its section is open. It
    /// opens by itself when the service knows the password in force.
    @State private var newPassword = ""
    @State private var repeatedPassword = ""
    @State private var settingNewPassword = false
    /// The token was withdrawn by a password change elsewhere.
    @State private var passwordWithdrawn = false
    /// The rounds stopped because the service is older than this app.
    @State private var serviceOlder = false
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
    /// The service refused the token and the session stopped on it. Read
    /// from the session like the last refusal: the keychain still holds
    /// the token, so "signed in" alone would say the opposite of the truth.
    @State private var tokenRefused = false
    /// The runner itself, observed: its block is what the page shows, and a
    /// mirror in `@State` showed the round before this one.
    @ObservedObject private var feedAuth = FeedAuthSync.shared
    /// The service key this device holds for the address in the form, and
    /// the event of the service offering a different one. The event stays
    /// on the page until the person answers it one way or the other; the
    /// form keeps what they typed, so answering is one tap and not a second
    /// sign-in.
    @State private var heldKey: String?
    @State private var keyChange: KeyChange?

    /// The event belongs to the address it came from: typing another
    /// address must not leave one service's key change standing under
    /// another service's form.
    nonisolated struct KeyChange: Equatable {
        var held: String
        var offered: String
        var address: String

        func stands(forAddress address: String) -> Bool { self.address == address }
    }

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
                                                 carrierIsTheService: carrierIsTheService,
                                                 signedIn: signedIn,
                                                 tokenRefused: tokenRefused,
                                                 serviceOlder: serviceOlder) {
                case .serviceOlder:
                    Label {
                        Text("The sync service is older than this app, so nothing travels. It works again once the service is updated.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("maer-sync-service-older")
                case .tokenRefused:
                    Label {
                        // The service says why when the password changed on
                        // another device, and then the remedy is the new
                        // password, not the old one again.
                        Group {
                            if passwordWithdrawn {
                                Text("The password was changed on another device, so this device's token no longer counts. Sign in with the new password.")
                            } else {
                                Text("The service refused this device's token, so nothing travels. Sign in again.")
                            }
                        }
                        .font(.footnote)
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                    }
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("maer-sync-token-refused")
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
                case .stalledUntilRestart:
                    // The one state where nothing travels at all, in either
                    // direction. The runner still holds this service and the
                    // service has no access, so there is nowhere left for a
                    // write to go. It is temporary and it is not small, and
                    // it used to look exactly like everything being fine.
                    Label {
                        Text("Signed out, but the running app still holds this service, so nothing travels at all right now. Restart Mär and your devices go back to iCloud.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "pause.circle")
                    }
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("maer-sync-stalled")
                case .notInUse:
                    Label {
                        Text("Not signed in, so this service carries nothing. Your devices use iCloud.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "icloud")
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("maer-sync-not-in-use")
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

                if !settingNewPassword {
                    Button {
                        settingNewPassword = true
                    } label: {
                        Label("Change password", systemImage: "key.horizontal")
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("maer-sync-change-password")
                }

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
                if let heldKey {
                    // Shown so it can be COMPARED: the service prints its
                    // own fingerprint to its operator, and a held key nobody
                    // can read is a promise nobody can check.
                    Label {
                        Text("Service key held by this device: \(heldKey)")
                            .font(.system(.footnote, design: .monospaced))
                    } icon: {
                        Image(systemName: "key")
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("maer-sync-held-key")
                }
            } footer: {
                Text("Podcast progress, the playback claim, the listening statistics, the playlists and your choices, from sorts to favorites, run over this service from the next start.")
            }

            if settingNewPassword {
                newPasswordSection
            }

            if let keyChange {
                keyChangeSection(keyChange)
            }

            if signedIn {
                feedAuthSection()
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
            refreshFromSession()
            // A refusal from a round in the background reaches the open
            // page through the session's ring, not at the next own change.
            MaerSyncCarriers.session.onRefusalChange = { refreshFromSession() }
            heldKey = MaerSyncSignIn.heldKey(forAddress: serverURL)
            // The event can also come from a round in the background, on a
            // device that is signed in: the session stops and keeps it here.
            if let change = MaerSyncCarriers.session.keyChange {
                keyChange = KeyChange(held: change.held, offered: change.offered, address: serverURL)
            }
        }
        .onDisappear { MaerSyncCarriers.session.onRefusalChange = nil }
        // The held line and the key change belong to the address in the
        // form: typing another address must not leave the old address's key
        // or its event standing under it.
        .onChange(of: serverURL) { _, address in
            heldKey = MaerSyncSignIn.heldKey(forAddress: address)
            if let keyChange, !keyChange.stands(forAddress: address) { self.keyChange = nil }
        }
    }

    /// The event: the service at this address offers a key this device does
    /// not hold. Both fingerprints stand there to be compared, and the two
    /// honest reasons for a change stand beside the one dishonest one; the
    /// person accepts or keeps, and nothing is sent until they do.
    @ViewBuilder
    /// The new password, typed twice. The password in force is the one in
    /// the form above; which of the two travels how is the sign-in's
    /// business, and the footer says the part a person must know.
    private var newPasswordSection: some View {
        Section {
            CredentialField.secret("New password", text: $newPassword, id: "maer-sync-new-password", new: true)
            CredentialField.secret("Repeat new password", text: $repeatedPassword, id: "maer-sync-repeat-password", new: true)
            Button {
                changePassword()
            } label: {
                Label("Set new password", systemImage: "key.horizontal.fill")
            }
            .disabled(isWorking || serverURL.isEmpty || owner.isEmpty || secret.isEmpty
                      || newPassword.isEmpty || repeatedPassword.isEmpty)
            .accessibilityIdentifier("maer-sync-set-new-password")
            Button(role: .cancel) {
                settingNewPassword = false
                newPassword = ""
                repeatedPassword = ""
            } label: {
                Text("Cancel")
            }
            .disabled(isWorking)
        } header: {
            Text("New password")
        } footer: {
            Text("At least 12 characters. Type the password in force above: an old one, or a one-time password from the service's operator. The new password never leaves this device; only a proof of it does.")
        }
    }

    private func keyChangeSection(_ change: KeyChange) -> some View {
        Section {
            Label {
                Text("The service at this address offers a different key than the one this device holds.")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            .accessibilityIdentifier("maer-sync-key-changed")
            LabeledContent("Held") {
                Text(change.held).font(.system(.footnote, design: .monospaced))
            }
            LabeledContent("Offered") {
                Text(change.offered).font(.system(.footnote, design: .monospaced))
            }
            if signedIn {
                // Already signed in: accepting holds the key and lets the
                // rounds run again at the next occasion; no secret needed.
                Button {
                    MaerSyncSignIn.acceptKey(change.offered, forAddress: serverURL)
                    keyChange = nil
                    heldKey = MaerSyncSignIn.heldKey(forAddress: serverURL)
                    setStatus(String(localized: "The new key is held. Syncing goes on at the next occasion."), isError: false)
                } label: {
                    Label("Accept the new key", systemImage: "key.viewfinder")
                }
                .disabled(isWorking || serverURL.isEmpty)
                .accessibilityIdentifier("maer-sync-key-accept")
            } else {
                Button {
                    signIn(acceptingKey: change.offered)
                } label: {
                    Label("Accept the new key and sign in", systemImage: "key.viewfinder")
                }
                .disabled(isWorking || serverURL.isEmpty || owner.isEmpty || secret.isEmpty)
                .accessibilityIdentifier("maer-sync-key-accept")
            }
            Button {
                keyChange = nil
                setStatus(String(localized: "The old key stays. Nothing was sent."), isError: false)
            } label: {
                Label("Keep the old key", systemImage: "lock")
            }
            .accessibilityIdentifier("maer-sync-key-keep")
        } footer: {
            Text("A key changes when the service moved to another machine or was restored from a backup. If you did not do that, someone between you and the service may be answering in its place. Compare the offered key with what the service prints about itself before you accept it.")
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
            case .plainAddressRefused:
                setStatus(String(localized: "iOS does not allow plain http for this address, so the service was never asked."), isError: true)
            }
        }
    }

    private func signIn(acceptingKey: String? = nil) {
        isWorking = true
        Task {
            defer { isWorking = false }
            show(await MaerSyncSignIn.perform(address: serverURL, owner: owner, password: secret,
                                              acceptingKey: acceptingKey))
        }
    }

    /// The new password, with its repetition; the sign-in asks the rule
    /// before it asks the service. The password in force is the one typed
    /// above (the old one, or the operator's one-time password).
    private func changePassword() {
        isWorking = true
        Task {
            defer { isWorking = false }
            show(await MaerSyncSignIn.changePassword(address: serverURL, owner: owner, current: secret,
                                                     new: newPassword, repeated: repeatedPassword))
        }
    }

    /// One sentence for every outcome, whichever button asked.
    private func show(_ outcome: MaerSyncSignIn.Outcome) {
        switch outcome {
        case .signedIn(let access, let account):
            newPassword = ""
            repeatedPassword = ""
            settingNewPassword = false
            MaerSyncSignIn.store(access, owner: account)
            serverURL = access.baseURL.absoluteString
            owner = account
            secret = ""
            signedIn = true
            // `store` told the session to read its access again, which
            // lifts the stop and the refusal; the page follows the
            // session's values.
            refreshFromSession()
            keyChange = nil
            heldKey = MaerSyncSignIn.heldKey(forAddress: serverURL)
            // The runner follows the sign-in at once: a runner that found
            // no access at the start starts now, with the feed key the
            // sign-in just kept.
            feedAuth.startIfConfigured(by: "settings sign-in")
            setStatus(String(localized: "Signed in."), isError: false)
        case .keyChanged(let held, let offered):
            keyChange = KeyChange(held: held, offered: offered, address: serverURL)
            setStatus(String(localized: "The service's key has changed. Nothing was sent."), isError: true)
        case .serviceHasNoKey:
            setStatus(String(localized: "The service has no key yet. Its operator starts it once so it makes one."), isError: true)
        case .serviceIsOlder:
            setStatus(String(localized: "The service does not offer a key, so it is older than this Mär. Update the service."), isError: true)
        case .serviceIsNewer:
            setStatus(String(localized: "The service is newer than this Mär. Update the app, then sign in."), isError: true)
        case .needsNewPassword:
            settingNewPassword = true
            setStatus(String(localized: "This account needs a new password before it can sign in. Nothing was sent."), isError: true)
        case .tooManyAttempts(let seconds):
            if let seconds {
                setStatus(String(localized: "Too many failed attempts. Try again in \(MaerSyncWait.minutes(seconds)) min."), isError: true)
            } else {
                setStatus(String(localized: "Too many failed attempts. Try again later."), isError: true)
            }
        case .unsafeParameters:
            setStatus(String(localized: "The service asked for sign-in settings this Mär does not accept. Nothing was sent."), isError: true)
        case .newPasswordTooShort(let missing):
            setStatus(String(localized: "The new password needs \(missing) more characters."), isError: true)
        case .newPasswordSameAsCurrent:
            setStatus(String(localized: "The new password must differ from the current one."), isError: true)
        case .newPasswordRepeatDiffers:
            setStatus(String(localized: "The two new passwords differ."), isError: true)
        case .localFailure:
            setStatus(String(localized: "This device could not prepare the new password. Nothing was sent."), isError: true)
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
        case .plainAddressRefused:
            // The platform said no before a byte left; the same
            // sentence as the test button, one story for one refusal.
            setStatus(String(localized: "iOS does not allow plain http for this address, so the service was never asked."), isError: true)
        }
    }

    private func signOut() {
        MaerSyncSignIn.signOut()
        signedIn = false
        refreshFromSession()
        setStatus(String(localized: "Signed out."), isError: false)
    }

    /// What the page reads off the session and the register, read again
    /// after every change this page makes: the last refusal, the refused
    /// token, and whether ANY runner holds the service. The last one used to
    /// ask whether ALL did, so a runner made late and alone on the service
    /// read as "your devices use iCloud" after a sign-out.
    private func refreshFromSession() {
        refusal = MaerSyncCarriers.session.lastRefusal
        tokenRefused = MaerSyncCarriers.session.unauthorized
        passwordWithdrawn = MaerSyncCarriers.session.passwordWithdrawn
        serviceOlder = MaerSyncCarriers.session.serviceOlder
        carrierIsTheService = CarrierChoices.anyTravelsTheService
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    /// The feed credentials: the state of the far side. They are sealed with
    /// a key that comes from the account's password, so there is no code to
    /// show or to carry to another device.
    ///
    /// **The price stands in the footer and not in an error.** Whoever relies
    /// on this has to know beforehand what a forgotten password costs;
    /// afterwards it is an apology.
    @ViewBuilder
    private func feedAuthSection() -> some View {
        let standing = FeedAuthStanding.standing(syncAcrossDevices: syncAcrossDevices,
                                                 hasService: signedIn,
                                                 block: feedAuth.block)
        Section {
            switch standing {
            case .carrying:
                EmptyView()
            case .needsCode:
                // Another device's block does not open here: sealed with a
                // password this device did not sign in with.
                Label {
                    Text("Another device sealed its feed credentials with a password this device did not sign in with.")
                } icon: {
                    Image(systemName: "lock")
                }
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("feed-auth-waiting")
            case .newerBuild:
                Label {
                    Text("A newer version of Mär wrote these credentials. This device leaves them alone.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .foregroundStyle(.secondary)
            case .switchedOff, .noService:
                EmptyView()
            }

            if FeedAuthStanding.notice(addressIsSecure: FeedAuthStanding.addressIsSecure(serverURL),
                                       standing: standing) == .plainAddress {
                // Named, never refused: the people this is built for are the
                // ones who cannot get a certificate. The sentence says what
                // is open on the wire, which since the sealed session is the
                // first key fetch and the reachability check, not the token.
                Label {
                    Text("This address is plain http. Your sign-in and everything the app exchanges with the service travel sealed inside the session. Only the first fetch of the service's key and the reachability check are open on the wire; from then on the app holds that key.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.orange)
                .accessibilityIdentifier("feed-auth-plain-address")
            }
        } header: {
            Text("Feed credentials")
        } footer: {
            Text("Usernames and passwords of private and paid feeds travel sealed with a key that comes from your account password, which the service never sees. If the password is forgotten and no device holds the credentials any more, they are gone.")
        }
    }

}
