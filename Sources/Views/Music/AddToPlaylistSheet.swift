// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The music item (a single song, or a whole album/playlist) a user picked to
/// add to a playlist. `Identifiable` so both context-menu hosts present the ONE
/// shared `AddToPlaylistSheet` via `.sheet(item:)` with no duplicated binding
/// glue (Regel 2 — the sheet is the single shared surface).
struct AddToPlaylistTarget: Identifiable {
    /// The namespaced media item id (`sub:song:…`, `sub:album:…`, `sub:playlist:…`).
    let itemId: String
    var id: String { itemId }
}

extension View {
    /// Present the shared add-to-playlist sheet for the given target. Both the
    /// music context menu (album/song) and the album track menu use this — one
    /// presentation path, one sheet.
    func addToPlaylistSheet(target: Binding<AddToPlaylistTarget?>) -> some View {
        sheet(item: target) { AddToPlaylistSheet(itemId: $0.itemId) }
    }
}

/// Pick an existing server playlist (or create a new one) and add the target's
/// songs to it. A single song contributes itself; an album/playlist contributes
/// all its tracks — the provider resolves that via `songIds(forItemId:)`.
struct AddToPlaylistSheet: View {
    let itemId: String

    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [SubsonicPlaylist] = []
    @State private var loading = true
    @State private var busy = false
    @State private var errorText: String?
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            List {
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        showNewPlaylist = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                    .disabled(busy)
                }

                Section("Playlists") {
                    if loading {
                        HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                    } else if playlists.isEmpty {
                        Text("No playlists yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(playlists) { playlist in
                            Button {
                                Task { await add(toItemId: AppSession.shared.musicProvider.itemId(playlistId: playlist.id)) }
                            } label: {
                                HStack {
                                    Text(playlist.name ?? String(localized: "Playlist"))
                                    Spacer()
                                    if let count = playlist.songCount {
                                        Text("\(count)").foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(busy)
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
            }
            .overlay {
                if busy { ProgressView().controlSize(.large) }
            }
            .task { await load() }
            // Create a new (empty) server playlist, then add straight into it.
            .alert("New Playlist", isPresented: $showNewPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Create") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    newPlaylistName = ""
                    guard !name.isEmpty else { return }
                    Task { await createAndAdd(name: name) }
                }
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
            } message: {
                Text("Create a playlist and add the selection to it.")
            }
        }
    }

    private func load() async {
        loading = true
        let all = (try? await AppSession.shared.musicProvider.allPlaylists()) ?? []
        playlists = PlaylistPresentation.realPlaylists(all)
        loading = false
    }

    private func add(toItemId playlistItemId: String) async {
        busy = true
        errorText = nil
        do {
            let ids = await AppSession.shared.musicProvider.songIds(forItemId: itemId)
            guard !ids.isEmpty else {
                errorText = String(localized: "Nothing to add.")
                busy = false
                return
            }
            try await AppSession.shared.musicProvider.addSongs(ids, toPlaylistItemId: playlistItemId)
            dismiss()
        } catch {
            errorText = String(localized: "Could not add to the playlist.")
            busy = false
        }
    }

    private func createAndAdd(name: String) async {
        busy = true
        errorText = nil
        do {
            guard let playlistItemId = try await AppSession.shared.musicProvider.createPlaylist(name: name) else {
                errorText = String(localized: "Could not create the playlist.")
                busy = false
                return
            }
            await add(toItemId: playlistItemId)
        } catch {
            errorText = String(localized: "Could not create the playlist.")
            busy = false
        }
    }
}
