// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Access to a gpodder-compatible sync server (oPodSync, Nextcloud GPodder,
/// gpodder.net). On par with iCloud and ABS. Enter server/user/password, test
/// the connection, enable it; subscriptions (and history) then reconcile
/// automatically when opening the podcast tab.
struct GPodderSettingsView: View {
    @State private var serverURL = AppStorageKeys.gpodderServerURLValue
    @State private var username = AppStorageKeys.gpodderUsernameValue
    @State private var password = AppStorageKeys.gpodderPasswordValue
    @State private var enabled = AppStorageKeys.gpodderEnabledValue
    /// Exclusivity note (gpodder turned ABS-podcasts off, or vice versa).
    @State private var podcastServerNote: String?

    @State private var isTesting = false
    @State private var isSyncing = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    // Last sync outcome, persisted across restarts (sticky guard warning).
    @State private var storedReport = GPodderSync.shared.storedReport

    var body: some View {
        Form {
            Section {
                CredentialField.serverURL("Server URL", text: $serverURL,
                                          id: "gpodder-url",
                                          service: .gpodder)
                CredentialField.username("Username", text: $username,
                                         id: "gpodder-username")
                CredentialField.secret("Password", text: $password,
                                       id: "gpodder-password")
            } header: {
                Text("gpodder Server")
            } footer: {
                Text("Works with oPodSync, Nextcloud GPodder and gpodder.net. Example: https://sync.example.com")
            }

            Section {
                AppSwitch("Sync podcasts via gpodder", isOn: $enabled)
                    // gpodder ↔ ABS-podcasts are mutually exclusive (one podcast
                    // server at a time; RSS untouched). Enabling gpodder turns ABS
                    // off, with a note so it's not surprising.
                    .onChange(of: enabled) {
                        if AppStorageKeys.setGpodderEnabled(enabled) {
                            podcastServerNote = String(localized: "Audiobookshelf podcasts were turned off: only one podcast server at a time.")
                        }
                    }
                LabeledContent("Device", value: AppStorageKeys.gpodderDeviceIdValue)
            } footer: {
                Text("Subscriptions (and listening history) sync with this server, alongside iCloud and Audiobookshelf. Feeds with a user name and password never travel this way; they follow your iCloud keychain. Whether premium feeds sync is decided under Podcasts, where this account acts.")
            }

            Section {
                Button {
                    save()
                    isTesting = true
                    Task {
                        // A press gets the answer of now, even during the
                        // rest after a refused connection.
                        let err = await LookupOccasion.deliberate { await GPodderSync.shared.testConnection() }
                        // Only a WORKING address is remembered.
                        if err == nil { KnownServers.remember(serverURL, service: .gpodder) }
                        setStatus(err ?? String(localized: "Connected."), isError: err != nil)
                        isTesting = false
                    }
                } label: {
                    Label("Test connection", systemImage: "bolt.horizontal")
                }
                .disabled(isTesting || serverURL.isEmpty)

                Button {
                    save()
                    isSyncing = true
                    Task {
                        let r = await GPodderSync.shared.reconcile()
                        setStatus(syncSummary(r), isError: r.error != nil)
                        storedReport = GPodderSync.shared.storedReport
                        isSyncing = false
                    }
                } label: {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                }
                .disabled(isSyncing || !enabled || serverURL.isEmpty)

                if isTesting || isSyncing {
                    HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) }
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
            }

            // Persisted last-sync outcome. Survives an app restart, and
            // the mass-delete guard warning stays until the next clean sync.
            if let stored = storedReport {
                Section {
                    LabeledContent("Last Sync",
                                   value: stored.date.formatted(date: .abbreviated, time: .shortened))
                    if let warning = stored.warning {
                        HintLine(systemImage: "exclamationmark.triangle.fill") { Text(warning) }
                        // The guard blocks but doesn't resolve. Offer a manual
                        // merge screen so the divergence can be converged.
                        NavigationLink {
                            GPodderConflictResolutionView()
                        } label: {
                            Label("Resolve conflict…", systemImage: "arrow.triangle.merge")
                        }
                        .onDisappear { storedReport = GPodderSync.shared.storedReport }
                    }
                    if let error = stored.report.error {
                        Label(error, systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                    Text(countsSummary(stored.report))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Last Sync")
                } footer: {
                    if stored.warning != nil {
                        Text("The subscription guard blocked an implausible mass removal. This warning stays until the next clean sync.")
                    }
                }
            }
        }
        .navigationTitle("gpodder Sync")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Podcast source changed", isPresented: Binding(
            get: { podcastServerNote != nil }, set: { if !$0 { podcastServerNote = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(podcastServerNote ?? "") }
        // Don't let the mini-player overlay overlap.
        .bottomBarClearance()
        // Save on leaving so nothing is lost.
        .onDisappear { save() }
        // The mask always prefills the LAST stored state.
        // Also refills fields the early @State init may have read empty.
        .onAppear {
            if serverURL.isEmpty { serverURL = AppStorageKeys.gpodderServerURLValue }
            if username.isEmpty { username = AppStorageKeys.gpodderUsernameValue }
            if password.isEmpty { password = AppStorageKeys.gpodderPasswordValue }
        }
    }

    private func save() {
        // As on the music source page: a transiently EMPTY
        // field must never erase the stored value. The unconditional save on
        // disappear could nuke URL, user AND the keychain password. Clearing
        // the source is done via the toggle, not by emptying fields.
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespaces)
        if !trimmedURL.isEmpty {
            AppStorageKeys.gpodderServerURLValue = trimmedURL
        }
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        if !trimmedUser.isEmpty {
            AppStorageKeys.gpodderUsernameValue = trimmedUser
        }
        if !password.isEmpty {
            AppStorageKeys.setGpodderPassword(password)
        }
        AppStorageKeys.setGpodderEnabled(enabled)   // enforces gpodder↔ABS exclusivity
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func syncSummary(_ r: GPodderSync.Report) -> String {
        if let error = r.error { return error }
        // Surface the mass-delete guard prominently instead of "in sync".
        if let warning = r.warning { return warning }
        var parts: [String] = []
        if r.addedLocally > 0 { parts.append(String(localized: "\(r.addedLocally) added from server")) }
        if r.pushedToServer > 0 { parts.append(String(localized: "\(r.pushedToServer) pushed to server")) }
        if r.historyPulled > 0 { parts.append(String(localized: "\(r.historyPulled) positions in")) }
        if r.historyPushed > 0 { parts.append(String(localized: "\(r.historyPushed) positions out")) }
        return parts.isEmpty ? String(localized: "Already in sync.") : parts.joined(separator: " · ")
    }

    /// Counts only (no warning/error). For the persisted last-sync section.
    private func countsSummary(_ r: GPodderSync.Report) -> String {
        var parts: [String] = []
        if r.addedLocally > 0 { parts.append(String(localized: "\(r.addedLocally) added from server")) }
        if r.pushedToServer > 0 { parts.append(String(localized: "\(r.pushedToServer) pushed to server")) }
        if r.historyPulled > 0 { parts.append(String(localized: "\(r.historyPulled) positions in")) }
        if r.historyPushed > 0 { parts.append(String(localized: "\(r.historyPushed) positions out")) }
        return parts.isEmpty ? String(localized: "Already in sync.") : parts.joined(separator: " · ")
    }
}
