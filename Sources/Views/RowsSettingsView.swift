// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The ROWS page: which tile rows appear, per tab, rendered from the one
/// enumeration (`AppRows`). Presentation only; the source question lives
/// on its own page. Fixed entries (the library's working set, the search)
/// say WHY they carry no switch instead of hiding.
struct RowsSettingsView: View {
    /// What the cleanup rule just switched off, per row key, for the
    /// inline note. Session-transient by design: the durable reason shows
    /// derived on the sources page.
    @State private var cleanupNotes: [String: [String]] = [:]

    var body: some View {
        Form {
            ForEach(AppRow.Tab.allCases, id: \.rawValue) { tab in
                Section {
                    ForEach(AppRows.all.filter { $0.tab == tab }) { row in
                        RowToggleRow(row: row,
                                     note: cleanupNotes[row.key]) { turnedOff in
                            cleanupNotes[row.key] = turnedOff.isEmpty ? nil : turnedOff
                        }
                    }
                } header: {
                    Text(Self.title(for: tab))
                }
            }
        }
        .navigationTitle(Text("Rows"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func title(for tab: AppRow.Tab) -> LocalizedStringKey {
        switch tab {
        case .home: "Home"
        case .audiobooks: "Audiobooks"
        case .music: "Music"
        case .podcasts: "Podcasts"
        case .radio: "Radio"
        }
    }
}

/// One row: its switch (writes through the ONE path so the cleanup rule
/// runs), the sources it draws from, and right after hiding also which
/// sources went off with it.
private struct RowToggleRow: View {
    let row: AppRow
    let note: [String]?
    let onCleanup: ([String]) -> Void
    @State private var visible: Bool

    init(row: AppRow, note: [String]?, onCleanup: @escaping ([String]) -> Void) {
        self.row = row
        self.note = note
        self.onCleanup = onCleanup
        _visible = State(initialValue: AppRows.isVisible(row))
    }

    private var sourcesLine: String? {
        let titles = row.sourceKeys.compactMap { ExternalSources.source(key: $0)?.title }
        guard !titles.isEmpty else { return nil }
        return String(localized: "Draws from: \(titles.joined(separator: " · "))")
    }

    /// Why a fixed entry carries no switch. The working set IS the
    /// library; the search asks only on the user's own query.
    private var fixedReason: LocalizedStringKey {
        row.sourceKeys.isEmpty
            ? "Your own holdings — always shown."
            : "Asks only when you search."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if row.toggleable {
                AppSwitch(isOn: Binding(
                    get: { visible },
                    set: { newValue in
                        visible = newValue
                        // The ONE write path: hiding runs the cleanup rule
                        // and hands back what went off with it.
                        let turnedOff = AppRows.setVisible(row, newValue)
                        onCleanup(turnedOff.compactMap {
                            ExternalSources.source(key: $0)?.title
                        })
                    }
                )) { Text(verbatim: row.title) }
                    .accessibilityIdentifier("row-toggle-\(row.key)")
            } else {
                Text(verbatim: row.title)
                Text(fixedReason)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let sourcesLine {
                Text(verbatim: sourcesLine)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let note, !note.isEmpty {
                // The rule acted; it says so where it acted. Visible, with
                // its reason, never silent.
                Text("Turned off with it: \(note.joined(separator: " · ")) — no visible row was using it.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
