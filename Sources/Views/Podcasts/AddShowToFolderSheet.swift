// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Puts a show into a folder: an existing one, or a new one with a name.
/// With a show it comes from the show's page; without one it comes from
/// "+" and offers the subscribed shows to start the new folder with. With
/// a folder to edit it comes from the folder's menu, the same sheet with
/// the folder's name and shows chosen, and Save changes that folder.
/// Create and Save stand where a sheet confirms on iOS, at the top right.
struct AddShowToFolderSheet: View {
    /// The show to file; nil makes a new folder from chosen shows.
    let show: PodcastShow?
    /// The folder to edit; nil makes a new one.
    let editing: MaerPlaylists.Playlist?
    @ObservedObject private var store = MaerPlaylists.shared
    /// The subscriptions as the sheet opened; a short choice needs no
    /// observation of them.
    private let shows = PodcastSubscriptions.shared.shows
    @Environment(\.dismiss) private var dismiss
    @State private var newName: String
    @State private var chosen: Set<String>
    /// The folder's own settings, shown when it is edited.
    @State private var settings: PodcastFolderSettings

    init(show: PodcastShow?, editing: MaerPlaylists.Playlist? = nil) {
        self.show = show
        self.editing = editing
        _newName = State(initialValue: editing?.name ?? "")
        _chosen = State(initialValue: Set(editing?.itemIds.compactMap(PodcastFolder.feedKey(of:)) ?? []))
        _settings = State(initialValue: editing.map { PodcastFolderSettings.read(folderId: $0.id) } ?? PodcastFolderSettings())
    }

    var body: some View {
        let folders = store.playlists.filter { PodcastFolder.isFolder($0.itemIds) }
        NavigationStack {
            Form {
                Section(editing == nil ? "New Folder" : "Name") {
                    TextField("Name", text: $newName)
                        .accessibilityIdentifier("podcast-folder-name")
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
                if editing != nil {
                    Section("Settings") {
                        Picker("Play starts", selection: $settings.start) {
                            Text("Newest episode of each show").tag(PodcastFolderStart.newestPerShow)
                            Text("All unheard, oldest first").tag(PodcastFolderStart.allUnheard)
                        }
                        .accessibilityIdentifier("podcast-folder-start")
                        AppSwitch(isOn: $settings.showsCount) { Text("Show the number of new episodes") }
                            .accessibilityIdentifier("podcast-folder-count")
                        Picker("Order of the shows", selection: $settings.order) {
                            Text("Newest episode first").tag(PodcastFolderOrderChoice.newestEpisode)
                            Text("Name").tag(PodcastFolderOrderChoice.name)
                            Text("By hand").tag(PodcastFolderOrderChoice.manual)
                        }
                        .accessibilityIdentifier("podcast-folder-order")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if let folder = editing {
                        Button("Save") { save(folder) }
                            .disabled(!canSave(folder))
                            .accessibilityIdentifier("podcast-folder-save")
                    } else {
                        Button("Create") { create() }
                            .disabled(!canCreate)
                            .accessibilityIdentifier("podcast-folder-create")
                    }
                }
            }
        }
        .softTopScrollEdge()
    }

    private var title: Text {
        if editing != nil { return Text("Edit Folder") }
        return show == nil ? Text("New Folder") : Text("Add to Folder")
    }

    private var candidates: [String] { shows.map { PodcastIdentity.feedKey($0.feedURL) } }

    private func canSave(_ folder: MaerPlaylists.Playlist) -> Bool {
        !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && PodcastFolder.remaining(folder.itemIds, after: PodcastFolder.edit(folder.itemIds, candidates: candidates, chosen: chosen)) > 0
    }

    /// The same folder with its new name and shows; no second one.
    private func save(_ folder: MaerPlaylists.Playlist) {
        let edit = PodcastFolder.edit(folder.itemIds, candidates: candidates, chosen: chosen)
        store.editFolder(id: folder.id, name: newName, join: edit.join, leave: edit.leave)
        if settings != PodcastFolderSettings.read(folderId: folder.id) {
            PodcastFolderSettings.write(settings, folderId: folder.id) { key, value in
                UserChoiceCloudSync.shared.noteScalar(key: key, value: value)
            }
        }
        dismiss()
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
