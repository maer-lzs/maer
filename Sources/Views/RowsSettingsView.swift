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
    /// Bumped after every write so the row reads the store again: the
    /// store is the truth, a mirror taken once at init showed the state
    /// of the first render forever.
    @State private var generation = 0

    private var visible: Bool {
        _ = generation
        return AppRows.isVisible(row)
    }

    /// Named only while the switch is ON and every source is off; a row
    /// with any feeding source left shows fewer tiles instead.
    private var unsourcedLine: String? {
        guard row.toggleable, visible,
              let titles = AppRows.unsourcedTitles(row,
                                                   podcastIndexConfigured: AppStorageKeys.podcastIndexConfigured,
                                                   isAllowed: { key in
                  ExternalSources.source(key: key).map { ExternalSources.isAllowed($0) } ?? false
              }) else { return nil }
        return String(localized: "Currently without a source. Switched off: \(titles.joined(separator: " · ")). See External Sources & Privacy.")
    }

    /// Why a fixed entry carries no switch. The working set IS the
    /// library; the search asks only on the user's own query.
    private var fixedReason: LocalizedStringKey {
        row.sourceKeys.isEmpty
            ? "Your own holdings, always shown."
            : "Asks only when you search."
    }

    var body: some View {
        if row.toggleable {
            // The lines under the title stand in the switch's label, so
            // they wrap before the switch instead of running under it.
            AppSwitch(isOn: Binding(
                get: { visible },
                set: { newValue in
                    // The ONE write path: hiding runs the cleanup rule
                    // and hands back what went off with it.
                    let turnedOff = AppRows.setVisible(row, newValue)
                    generation += 1
                    onCleanup(turnedOff.compactMap {
                        ExternalSources.source(key: $0)?.title
                    })
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.title)
                    lines
                }
            }
            .accessibilityIdentifier("row-toggle-\(row.key)")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.title)
                Text(fixedReason)
                    .font(.caption).foregroundStyle(.secondary)
                lines
            }
        }
    }

    /// The lines under a row's title. The sources line is in the same
    /// grey and size as the other second lines: the tertiary grey measured
    /// 1.7 to 1 against the cell (light) and 2.5 to 1 (dark).
    @ViewBuilder
    private var lines: some View {
        if let unsourced = unsourcedLine {
            // The visible row that CANNOT appear says so where its
            // switch lives; the surfaces stay quiet on purpose (the
            // absence is the user's own source choice).
            Text(verbatim: unsourced)
                .font(.caption).foregroundStyle(.orange)
        }
        if let subline = AppRows.subline(row, podcastIndexConfigured: AppStorageKeys.podcastIndexConfigured) {
            Text(verbatim: subline)
                .font(.caption).foregroundStyle(.secondary)
        }
        if let note, !note.isEmpty {
            // The rule acted; it says so where it acted. Visible, with
            // its reason, never silent.
            Text("Turned off with it: \(note.joined(separator: " · ")). No visible row was using it.")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
