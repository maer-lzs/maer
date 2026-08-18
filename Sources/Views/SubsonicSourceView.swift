// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Configure a Subsonic-compatible music server (Navidrome, Gonic, Airsonic).
/// Enter server/user/password, test the connection, switch it on — the Music tab
/// then appears in the library. Source-specific management, like the podcast and
/// gpodder source views.
struct SubsonicSourceView: View {
    @State private var serverURL = AppStorageKeys.subsonicServerURLValue
    @State private var username = AppStorageKeys.subsonicUsernameValue
    @State private var password = AppStorageKeys.subsonicPasswordValue
    @State private var enabled = AppStorageKeys.subsonicEnabledValue
    @State private var servesMusic = AppStorageKeys.subsonicModes.servesMusic
    @State private var servesAudiobooks = AppStorageKeys.subsonicModes.servesAudiobooks
    private var modes: SourceModes {
        SourceModes(servesMusic: servesMusic, servesAudiobooks: servesAudiobooks)
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

            Section {
                // the owner's Regel: was mehrere Dinge kann, darf sie
                // GLEICHZEITIG — ein Server, ein Setup. Deshalb je ein
                // Schalter pro Faehigkeit statt einer Entweder-oder-Wahl.
                Toggle(isOn: $servesMusic) {
                    Label("Music", systemImage: "music.note")
                }
                .accessibilityIdentifier("subsonic-serves-music")
                .onChange(of: servesMusic) { _, _ in save() }
                Toggle(isOn: $servesAudiobooks) {
                    Label("Audiobooks", systemImage: "books.vertical")
                }
                .accessibilityIdentifier("subsonic-serves-audiobooks")
                .onChange(of: servesAudiobooks) { _, _ in save() }
                if modes.isEmpty {
                    // Says it, instead of looking like a defect: nothing
                    // selected means this server feeds nothing — the
                    // credentials stay, the source simply rests.
                    Label("Nothing selected — this server currently feeds no tab. Its login stays saved.",
                          systemImage: "moon.zzz")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("subsonic-modes-empty")
                }
                if modes.needsLibraryAssignment {
                    // G8: sichtbar unvollstaendig statt eines leeren Tabs. Die
                    // Zuordnung, welche Bibliothek welchen Typ speist, kommt
                    // als eigener Schritt — bis dahin sagt die Flaeche, was
                    // fehlt, statt es zu verschweigen.
                    Label("Both modes are on. Which library feeds which tab is not assigned yet — until then this server is used for audiobooks.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("subsonic-modes-incomplete")
                }
            } header: {
                Text("This source contains")
            } footer: {
                Text("Booksonic libraries serve audiobooks: albums appear as books in the Audiobooks tab, tracks become chapters. Never guessed — you set it here.")
            }

            Section {
                // affb7e6: the tab is the USER's master (settings →
                // Libraries); this switch governs the SOURCE — its old label
                // ("Show Music tab") promised tab behaviour it no longer has.
                Toggle("Music server (Subsonic)", isOn: $enabled)
                    // Locale-independent handle for the UI-test harness.
                    .accessibilityIdentifier("music-tab-toggle")
                    // Y37: the toggle acts IMMEDIATELY (like the ABS podcast
                    // toggle) — save rebuilds the client and notifies the tab
                    // bar; before, nothing happened until the view closed.
                    .onChange(of: enabled) { _, _ in save() }
            } footer: {
                Text("When on, your albums, artists and playlists appear in a Music tab in the library.")
            }

            // a449534: the metadata feature toggles moved to the MUSIC pill in
            // Settings (provider-wide, not source access) — see musicSection.
            Section {
                Button {
                    save()
                    isTesting = true
                    Task {
                        let err = await SubsonicProvider.shared.testConnection()
                        // d990695: only a WORKING address is remembered.
                        if err == nil { KnownServers.remember(serverURL, service: .subsonic) }
                        setStatus(err ?? String(localized: "Connected."), isError: err != nil)
                        isTesting = false
                    }
                } label: {
                    Label("Test connection", systemImage: "bolt.horizontal")
                }
                .disabled(isTesting || serverURL.isEmpty || username.isEmpty)

                // Y27: the library refresh as a VISIBLE sync (parity with the
                // other sources) — lands in Settings → Sync → Sync History.
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
        .navigationTitle("Music Server")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        // Save on leaving so nothing is lost.
        .onDisappear { save() }
        // Y26: the mask always prefills the LAST stored state — a kicked-out
        // session costs at most the password re-entry. Also refills fields the
        // early @State init may have read empty.
        .onAppear {
            if serverURL.isEmpty { serverURL = AppStorageKeys.subsonicServerURLValue }
            if username.isEmpty { username = AppStorageKeys.subsonicUsernameValue }
            if password.isEmpty { password = AppStorageKeys.subsonicPasswordValue }
        }
    }

    private func save() {
        // Y26 class (Y38): a transiently EMPTY field must never erase the
        // stored value — the unconditional save on disappear nuked the server
        // URL, which (since Y37 reacts live) drops the Music tab on the spot.
        // Same decision as the password below: clearing a source is done via
        // the toggle, not by emptying a field.
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespaces)
        if !trimmedURL.isEmpty {
            AppStorageKeys.subsonicServerURLValue = trimmedURL
        }
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        if !trimmedUser.isEmpty {
            AppStorageKeys.subsonicUsernameValue = trimmedUser
        }
        // Y26: NEVER persist an empty field as a keychain DELETE — when the
        // @State init read the password as empty (locked-device keychain
        // failure), the unconditional save on disappear silently erased the
        // stored credential. An empty field simply leaves the keychain alone.
        if !password.isEmpty {
            AppStorageKeys.setSubsonicPassword(password)
        }
        AppStorageKeys.subsonicEnabledValue = enabled
        AppStorageKeys.subsonicModes = modes
        // Rebuild the client so the next request uses the new credentials —
        // via the session so BOTH music clients and the tab bar reconfigure.
        AppSession.shared.reconfigureSources()
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
