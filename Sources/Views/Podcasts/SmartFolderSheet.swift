// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The suggestions a preview shows, as the item of its sheet.
struct SmartFolderPreview: Identifiable {
    let suggestions: [SmartFolderSuggestion.Suggestion]
    var id: String { suggestions.map(\.category).joined(separator: "|") }
}

/// The line that offers folders by topic; nothing happens without a tap.
struct SmartFolderHint: View {
    let open: () -> Void
    let putAway: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                Label("Suggest Folders", systemImage: "sparkles")
                    .font(.subheadline)
            }
            .accessibilityIdentifier("smart-folders-hint")
            Spacer(minLength: 0)
            Button(action: putAway) {
                Image(systemName: "xmark").font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Hide Suggestion"))
            .accessibilityIdentifier("smart-folders-hint-hide")
        }
    }
}

/// The preview of the suggested folders: every show ticked, a tap takes
/// a show out; Create makes the folders with what stays ticked.
struct SmartFolderSheet: View {
    let suggestions: [SmartFolderSuggestion.Suggestion]
    let titles: [String: String]
    /// The row's store: the sheet holds no store of its own.
    let store: MaerPlaylists
    @Environment(\.dismiss) private var dismiss
    @State private var ticked: Set<String>

    init(suggestions: [SmartFolderSuggestion.Suggestion], titles: [String: String], store: MaerPlaylists) {
        self.suggestions = suggestions
        self.titles = titles
        self.store = store
        _ticked = State(initialValue: Set(suggestions.flatMap(\.keys)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("The topics come from each show's own feed. Shows already in a folder stay where they are.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(suggestions, id: \.category) { suggestion in
                    Section(SmartFolderSuggestion.name(for: suggestion.category)) {
                        ForEach(suggestion.keys, id: \.self) { key in
                            Button {
                                if ticked.contains(key) { ticked.remove(key) } else { ticked.insert(key) }
                            } label: {
                                Label(titles[key] ?? key, systemImage: ticked.contains(key) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text("Folders by Topic"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        SmartFolders.create(suggestions, ticked: ticked, in: store)
                        dismiss()
                    }
                    .disabled(ticked.isEmpty)
                    .accessibilityIdentifier("smart-folders-create")
                }
            }
        }
    }
}
