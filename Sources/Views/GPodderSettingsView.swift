// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Access to a gpodder-compatible sync server (oPodSync, Nextcloud GPodder,
/// gpodder.net) — on par with iCloud and ABS. Enter server/user/password, test
/// the connection, enable it; subscriptions (and history) then reconcile
/// automatically when opening the podcast tab.
struct GPodderSettingsView: View {
    @State private var serverURL = AppStorageKeys.gpodderServerURLValue
    @State private var username = AppStorageKeys.gpodderUsernameValue
    @State private var password = AppStorageKeys.gpodderPasswordValue
    @State private var enabled = AppStorageKeys.gpodderEnabledValue

    @State private var isTesting = false
    @State private var isSyncing = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    // S20: last sync outcome, persisted across restarts (sticky guard warning).
    @State private var storedReport = GPodderSync.shared.storedReport

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
                Text("gpodder Server")
            } footer: {
                Text("Works with oPodSync, Nextcloud GPodder and gpodder.net. Example: https://sync.example.com")
            }

            Section {
                Toggle("Sync podcasts via gpodder", isOn: $enabled)
                LabeledContent("Device", value: AppStorageKeys.gpodderDeviceIdValue)
            } footer: {
                Text("Subscriptions (and listening history) sync with this server, alongside iCloud and Audiobookshelf.")
            }

            Section {
                Button {
                    save()
                    isTesting = true
                    Task {
                        let err = await GPodderSync.shared.testConnection()
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

            // S20: persisted last-sync outcome — survives an app restart, and
            // the mass-delete guard warning stays until the next clean sync.
            if let stored = storedReport {
                Section {
                    LabeledContent("Last sync",
                                   value: stored.date.formatted(date: .abbreviated, time: .shortened))
                    if let warning = stored.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                        // The guard blocks but doesn't resolve — offer a manual
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
        // Don't let the mini-player overlay overlap.
        .bottomBarClearance()
        // Save on leaving so nothing is lost.
        .onDisappear { save() }
        // Y26/Y38 parity: the mask always prefills the LAST stored state —
        // also refills fields the early @State init may have read empty.
        .onAppear {
            if serverURL.isEmpty { serverURL = AppStorageKeys.gpodderServerURLValue }
            if username.isEmpty { username = AppStorageKeys.gpodderUsernameValue }
            if password.isEmpty { password = AppStorageKeys.gpodderPasswordValue }
        }
    }

    private func save() {
        // Y26 class (Y38, parity with the music source): a transiently EMPTY
        // field must never erase the stored value — the unconditional save on
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
        AppStorageKeys.gpodderEnabledValue = enabled
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

    /// Counts only (no warning/error) — for the persisted last-sync section.
    private func countsSummary(_ r: GPodderSync.Report) -> String {
        var parts: [String] = []
        if r.addedLocally > 0 { parts.append(String(localized: "\(r.addedLocally) added from server")) }
        if r.pushedToServer > 0 { parts.append(String(localized: "\(r.pushedToServer) pushed to server")) }
        if r.historyPulled > 0 { parts.append(String(localized: "\(r.historyPulled) positions in")) }
        if r.historyPushed > 0 { parts.append(String(localized: "\(r.historyPushed) positions out")) }
        return parts.isEmpty ? String(localized: "Already in sync.") : parts.joined(separator: " · ")
    }
}
