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
    /// How far the switches of a group of shares stand in under the
    /// group's title; it grows with the text like the rows it indents.
    @ScaledMetric(relativeTo: .body) private var groupIndent: CGFloat = 16

    var body: some View {
        Form {
            ForEach(AppRow.Tab.allCases, id: \.rawValue) { tab in
                Section {
                    let rows = AppRows.all.filter { $0.tab == tab }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        // A group of shares (Browse) stands under its own
                        // title, its switches indented beneath it.
                        if let group = row.group, index == 0 || rows[index - 1].group != group,
                           let title = AppRows.groupTitle(group) {
                            Text(verbatim: title).font(.subheadline.weight(.semibold))
                        }
                        RowToggleRow(row: row,
                                     note: cleanupNotes[row.key]) { turnedOff in
                            cleanupNotes[row.key] = turnedOff.isEmpty ? nil : turnedOff
                        }
                        .padding(.leading, row.group == nil ? 0 : groupIndent)
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
                // Why it carries no switch, named by the entry itself.
                Text(verbatim: row.fixed?.reason ?? "")
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
