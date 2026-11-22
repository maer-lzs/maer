// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Puts a show into a folder: an existing one, or a new one with a name.
/// With a show it comes from the show's page; without one it comes from
/// "+" and offers the subscribed shows to start the new folder with.
struct AddShowToFolderSheet: View {
    /// The show to file; nil makes a new folder from chosen shows.
    let show: PodcastShow?
    @ObservedObject private var store = MaerPlaylists.shared
    /// The subscriptions as the sheet opened; a short choice needs no
    /// observation of them.
    private let shows = PodcastSubscriptions.shared.shows
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var chosen: Set<String> = []

    var body: some View {
        let folders = store.playlists.filter { PodcastFolder.isFolder($0.itemIds) }
        NavigationStack {
            Form {
                Section("New Folder") {
                    TextField("Name", text: $newName)
                        .accessibilityIdentifier("podcast-folder-name")
                    Button("Create") { create() }
                        .disabled(!canCreate)
                        .accessibilityIdentifier("podcast-folder-create")
                }
                if let show, !folders.isEmpty {
                    let entry = PodcastFolder.entry(feedKey: PodcastIdentity.feedKey(show.feedURL))
                    Section("Folders") {
                        ForEach(folders) { folder in
                            Button {
                                store.file(show: PodcastIdentity.feedKey(show.feedURL), into: folder.id)
                                dismiss()
                            } label: {
                                Label(folder.name, systemImage: folder.itemIds.contains(entry) ? "checkmark.circle.fill" : "folder")
                            }
                        }
                    }
                }
                if show == nil {
                    Section("Subscriptions") {
                        ForEach(shows, id: \.id) { candidate in
                            let key = PodcastIdentity.feedKey(candidate.feedURL)
                            Button {
                                if chosen.contains(key) { chosen.remove(key) } else { chosen.insert(key) }
                            } label: {
                                Label(candidate.title, systemImage: chosen.contains(key) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle(show == nil ? Text("New Folder") : Text("Add to Folder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .softTopScrollEdge()
    }

    private var canCreate: Bool {
        !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (show != nil || !chosen.isEmpty)
    }

    /// A folder is never empty: it is made with its first show, the others
    /// follow in the order of the subscriptions.
    private func create() {
        let keys = show.map { [PodcastIdentity.feedKey($0.feedURL)] }
            ?? shows.map { PodcastIdentity.feedKey($0.feedURL) }.filter(chosen.contains)
        guard let first = keys.first else { return }
        let folder = store.createFolder(name: newName, show: first)
        keys.dropFirst().forEach { store.file(show: $0, into: folder.id) }
        dismiss()
    }
}
