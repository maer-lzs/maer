// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

extension View {
    /// At accessibility sizes a menu picker cuts its value to a few letters
    /// (measured at AX3: „Wie für…lle (Alle)“), so there the choices stand
    /// as rows, each whole.
    func choicesAsRowsWhenLarge() -> some View {
        modifier(ChoicesAsRowsWhenLarge())
    }
}

private struct ChoicesAsRowsWhenLarge: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.pickerStyle(.inline)
        } else {
            content.pickerStyle(.menu)
        }
    }
}

/// "For all shows" on the Podcasts pill: the three values
/// every show follows unless it has its own, and below them the shows that
/// do, each opening its own sheet. A change that would meet a show's own
/// value, or cost followers episodes, asks first.
struct PodcastGeneralSection: View {
    @State private var generals: [PodcastGeneralField: String] = [:]
    @State private var shows: [PodcastShow] = []
    @State private var question: PodcastGeneralSettings.Question?
    @State private var opened: PodcastShow?

    private var ownShows: [(show: PodcastShow, differences: [String])] {
        shows.compactMap { show in
            let differences = PodcastGeneralSettings.differences(of: show)
            return differences.isEmpty ? nil : (show, differences)
        }
    }

    var body: some View {
        Group {
            Section {
                ForEach(PodcastGeneralField.allCases) { field in
                    Picker(field.name, selection: binding(field)) {
                        ForEach(field.choices, id: \.self) { raw in
                            Text(field.label(raw)).tag(raw)
                        }
                    }
                    .choicesAsRowsWhenLarge()
                }
            } header: {
                Text("For All Shows")
            } footer: {
                Text("A new show follows these. A show with its own setting keeps it unless you overwrite all.")
            }
            let own = ownShows
            if !own.isEmpty {
                Section {
                    ForEach(own, id: \.show.id) { entry in
                        Button { opened = entry.show } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.show.title).foregroundStyle(.primary)
                                Text(verbatim: entry.differences.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Shows With Their Own Settings (\(own.count))")
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $opened, onDismiss: reload) { show in
            PodcastShowSettingsEntry(show: show).followsAppearanceChoice()
        }
        .alert("Change for all shows?",
               isPresented: Binding(get: { question != nil }, set: { if !$0 { question = nil } }),
               presenting: question) { asked in
            if asked.own.isEmpty {
                Button("Change", role: .destructive) { answer(asked, .keepOwn) }
            } else {
                Button("Overwrite All", role: .destructive) { answer(asked, .overwriteAll) }
                Button("Only Shows Without Their Own") { answer(asked, .keepOwn) }
            }
            Button("Cancel", role: .cancel) { question = nil }
        } message: { asked in
            Text(verbatim: asked.message)
        }
    }

    /// The picker shows the stored general value, so a cancelled question
    /// leaves it where it was.
    private func binding(_ field: PodcastGeneralField) -> Binding<String> {
        Binding(
            get: { generals[field] ?? field.general },
            set: { new in
                if let asked = PodcastGeneralSettings.question(field: field, new: new, shows: shows) {
                    question = asked
                } else {
                    PodcastGeneralSettings.apply(field: field, new: new, answer: .keepOwn, shows: shows)
                    reload()
                }
            })
    }

    private func answer(_ asked: PodcastGeneralSettings.Question, _ answer: PodcastGeneralRule.Answer) {
        PodcastGeneralSettings.apply(field: asked.field, new: asked.new, answer: answer, shows: shows)
        question = nil
        reload()
    }

    private func reload() {
        shows = PodcastGeneralSettings.shows()
        generals = Dictionary(uniqueKeysWithValues: PodcastGeneralField.allCases.map { ($0, $0.general) })
    }
}
