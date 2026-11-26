// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The place of the suggested folders in the podcast settings: the switch
/// of the hint in the folders row (on the one key the hint's cross puts
/// away), and the way to the preview, also below eight subscriptions,
/// while there is a suggestion.
struct SmartFolderSettingsSection: View {
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @ObservedObject private var store = MaerPlaylists.shared
    @AppStorage(AppStorageKeys.smartFoldersHintDismissed) private var hintDismissed = false
    @State private var previewing: [SmartFolderSuggestion.Suggestion]?

    var body: some View {
        let subscriptions = subs.shows
        let folders = store.playlists.filter { PodcastFolder.isFolder($0.itemIds) }
        let suggestions = SmartFolderSuggestion.suggest(SmartFolders.shows(subscriptions, folders: folders),
                                                        folderNames: Set(folders.map(\.name)))
        Section {
            AppSwitch(isOn: Binding(get: { !hintDismissed }, set: { hintDismissed = !$0 })) {
                Text("Suggest Folders")
            }
            .accessibilityIdentifier("smart-folders-setting")
            Button {
                previewing = suggestions
            } label: {
                Text("Folders by Topic…")
            }
            .disabled(!SmartFolderSuggestion.offersPreview(suggestions: suggestions.count))
            .accessibilityIdentifier("smart-folders-setting-preview")
        } footer: {
            if SmartFolderSuggestion.offersPreview(suggestions: suggestions.count) {
                Text("Folders from the topic each show names in its own feed.")
            } else {
                Text("No topic is shared by two shows that are not in a folder yet.")
            }
        }
        .sheet(item: Binding(get: { previewing.map(SmartFolderPreview.init) }, set: { previewing = $0?.suggestions })) { preview in
            SmartFolderSheet(suggestions: preview.suggestions, titles: Dictionary(
                subscriptions.map { (PodcastIdentity.feedKey($0.feedURL), $0.title) }, uniquingKeysWith: { first, _ in first }),
                store: store)
                .followsAppearanceChoice()
        }
    }
}
