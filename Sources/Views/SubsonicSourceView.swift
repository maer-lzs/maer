// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Configure a Subsonic-compatible music server (Navidrome, Gonic, Airsonic).
/// Enter server/user/password, test the connection, switch it on. The Music tab
/// then appears in the library. Source-specific management, like the podcast and
/// gpodder source views.
struct SubsonicSourceView: View {
    @State private var serverURL = AppStorageKeys.subsonicServerURLValue
    @State private var username = AppStorageKeys.subsonicUsernameValue
    @State private var password = AppStorageKeys.subsonicPasswordValue
    @State private var enabled = AppStorageKeys.subsonicEnabledValue
    @State private var servesMusic = AppStorageKeys.subsonicModes.servesMusic
    @State private var servesAudiobooks = AppStorageKeys.subsonicModes.servesAudiobooks
    @State private var libraries = AppStorageKeys.subsonicKnownLibraries
    @State private var assignment = AppStorageKeys.subsonicAssignment
    private var modes: SourceModes {
        SourceModes(servesMusic: servesMusic, servesAudiobooks: servesAudiobooks)
    }
    /// Enough to build a client with. Without it the reload button would
    /// promise a round trip that cannot happen.
    private var canReachServer: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var libraryReload: (() async -> Void)? {
        guard canReachServer else { return nil }
        return { await loadLibraries() }
    }
    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        Form {
            Section {
                CredentialField.serverURL("Server URL", text: $serverURL,
                                          id: "subsonic-url",
                                          service: .subsonic)
                CredentialField.username("Username", text: $username,
                                         id: "subsonic-username")
                CredentialField.secret("Password", text: $password,
                                       id: "subsonic-password")
            } header: {
                Text("Subsonic Server")
            } footer: {
                Text("Works with Navidrome, Gonic and Airsonic. Example: https://music.example.com")
            }

            CustomHeadersSection(address: serverURL, idPrefix: "subsonic")

            Section {
                // What can do several things may do them AT ONCE. One server,
                // one setup. Hence one switch per capability instead of an
                // either-or choice.
                AppSwitch(isOn: $servesMusic) {
                    Label("Music", systemImage: "music.note")
                }
                .accessibilityIdentifier("subsonic-serves-music")
                .onChange(of: servesMusic) { _, _ in
                    save()
                    loadLibrariesIfAssignmentBecameNecessary()
                }
                AppSwitch(isOn: $servesAudiobooks) {
                    Label("Audiobooks", systemImage: "books.vertical")
                }
                .accessibilityIdentifier("subsonic-serves-audiobooks")
                .onChange(of: servesAudiobooks) { _, _ in
                    save()
                    loadLibrariesIfAssignmentBecameNecessary()
                }
                if modes.isEmpty {
                    // Says it, instead of looking like a defect: nothing
                    // selected means this server feeds nothing. The
                    // credentials stay, the source simply rests.
                    Label("Nothing selected. This server currently feeds no tab. Its login stays saved.",
                          systemImage: "moon.zzz")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("subsonic-modes-empty")
                }
            } header: {
                Text("This source contains")
            } footer: {
                Text("Booksonic libraries serve audiobooks: albums appear as books in the Audiobooks tab, tracks become chapters. Never guessed: you set it here.")
            }

            // With two modes on, what each one is fed from has
            // to be said before either becomes a tab.
            SourceLibraryAssignmentSection(
                modes: modes,
                libraries: libraries,
                assignment: $assignment,
                reload: libraryReload)

            Section {
                // The tab is the USER's master (settings →
                // Libraries); this switch governs the SOURCE. Its old label
                // ("Show Music tab") promised tab behaviour it no longer has.
                AppSwitch("Music server (Subsonic)", isOn: $enabled)
                    // Locale-independent handle for the UI-test harness.
                    .accessibilityIdentifier("music-tab-toggle")
                    // The toggle acts IMMEDIATELY (like the ABS podcast
                    // toggle). Save rebuilds the client and notifies the tab
                    // bar; before, nothing happened until the view closed.
                    .onChange(of: enabled) { _, _ in save() }
            } footer: {
                Text("When on, your albums, artists and playlists appear in a Music tab in the library.")
            }

            // The metadata feature toggles moved to the MUSIC pill in
            // Settings (provider-wide, not source access). See musicSection.
            Section {
                Button {
                    save()
                    isTesting = true
                    Task {
                        // A press gets the answer of now, even during the
                        // rest after a refused connection.
                        var err = await LookupOccasion.deliberate { await SubsonicProvider.shared.testConnection() }
                        // Only a WORKING address is remembered.
                        if err == nil { KnownServers.remember(serverURL, service: .subsonic) }
                        if let failure = err { err = await AccessGuard.sentence(after: failure, address: serverURL) }
                        setStatus(err ?? String(localized: "Connected."), isError: err != nil)
                        isTesting = false
                    }
                } label: {
                    Label("Test connection", systemImage: "bolt.horizontal")
                }
                .disabled(isTesting || !SourceReadiness.fieldsFilled(address: serverURL, username: username))
                .accessibilityIdentifier("subsonic-test-connection")

                // The library refresh as a VISIBLE sync (parity with the
                // other sources). Lands in Settings → Sync → Sync History.
                Button {
                    save()
                    isTesting = true
                    Task {
                        let err = await SubsonicProvider.shared.syncLibraryNow()
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
                        // The outcome as a handle, for the server journeys; the colour alone is no handle.
                        .accessibilityIdentifier(statusIsError ? "subsonic-status-error" : "subsonic-status-ok")
                }
            }
        }
        .navigationTitle("Music Server")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        // Save on leaving so nothing is lost.
        .onDisappear { save() }
        // The mask always prefills the LAST stored state. A kicked-out
        // session costs at most the password re-entry. Also refills fields the
        // early @State init may have read empty.
        .onAppear {
            if serverURL.isEmpty { serverURL = AppStorageKeys.subsonicServerURLValue }
            if username.isEmpty { username = AppStorageKeys.subsonicUsernameValue }
            if password.isEmpty { password = AppStorageKeys.subsonicPasswordValue }
        }
    }

    private func save() {
        // A transiently EMPTY field must never erase the stored value. An
        // unconditional save on disappear would clear the server URL, and
        // the Music tab reacts to that live and drops on the spot.
        // Same decision as the password below: clearing a source is done via
        // the toggle, not by emptying a field.
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespaces)
        if !trimmedURL.isEmpty {
            // The password of the stored server stays with it, also the one
            // the field was filled with.
            password = SubsonicProvider.passwordAfterAddress(trimmedURL, typed: password)
            SubsonicProvider.forgetAccessOnSwitch(to: trimmedURL)
            AppStorageKeys.subsonicServerURLValue = trimmedURL
        }
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        if !trimmedUser.isEmpty {
            AppStorageKeys.subsonicUsernameValue = trimmedUser
        }
        // NEVER persist an empty field as a keychain DELETE. When the
        // @State init read the password as empty (locked-device keychain
        // failure), the unconditional save on disappear silently erased the
        // stored credential. An empty field simply leaves the keychain alone.
        if !password.isEmpty {
            AppStorageKeys.setSubsonicPassword(password)
        }
        AppStorageKeys.subsonicEnabledValue = enabled
        AppStorageKeys.subsonicModes = modes
        AppStorageKeys.subsonicAssignment = assignment
        // Rebuild the client so the next request uses the new credentials.
        // Via the session so BOTH music clients and the tab bar reconfigure.
        AppSession.shared.reconfigureSources()
    }

    /// Fetch the server's libraries. Saving first is not tidiness: the client
    /// is built from the STORED credentials, so a freshly typed address would
    /// otherwise be asked with the old one.
    private func loadLibraries() async {
        save()
        // A failure keeps the list shown and says so in the status line,
        // like the test and the sync.
        switch await FetchAnswer.of("subsonic libraries", logger: .music, { try await SubsonicProvider.shared.refreshLibraries() }) {
        case .value(let fetched):
            libraries = fetched
        case .failed:
            setStatus(String(localized: "The library could not be reached. Check the server and try again."), isError: true)
        case .cancelled:
            break
        }
        // Pruning may have dropped assignments for libraries that are gone.
        assignment = AppStorageKeys.subsonicAssignment
    }

    /// A second mode without a library list would show nothing but a question.
    /// Asking the server the moment the question arises is the difference
    /// between a screen that works and one that waits to be poked.
    private func loadLibrariesIfAssignmentBecameNecessary() {
        guard modes.needsLibraryAssignment, libraries.isEmpty, canReachServer else { return }
        Task { await loadLibraries() }
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
