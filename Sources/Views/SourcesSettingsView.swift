// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The SOURCES page: whom may this app ask. Rendered from the one
/// enumeration (`ExternalSources`), grouped by what the listener loses,
/// with the effect line per source and the rows it feeds. The user's own
/// servers are deliberately absent: they are infrastructure, not a
/// foreign source.
struct SourcesSettingsView: View {
    /// Bumped by the collective action so every row re-reads its key.
    /// (`@AppStorage` inside the rows cannot see writes that bypass it.)
    @State private var refresh = 0

    var body: some View {
        Form {
            ForEach(ExternalSourceGroup.allCases, id: \.rawValue) { group in
                Section {
                    ForEach(ExternalSources.all.filter { $0.group == group }) { source in
                        SourceToggleRow(source: source)
                            .id("\(source.key)-\(refresh)")
                    }
                } header: {
                    Text(Self.title(for: group))
                } footer: {
                    if let footer = Self.footer(for: group) { Text(footer) }
                }
            }
            Section {
                // The collective operation is an ACTION: it flips the
                // per-source switches and means nothing afterwards. The
                // master it replaces was a STATE over them.
                Button(role: .destructive) {
                    ExternalSources.disableAll()
                    refresh += 1
                } label: {
                    Text("Turn Every Source Off")
                }
                .accessibilityIdentifier("sources-all-off")
            } footer: {
                Text("Turns each switch above off, one by one. There is no overriding master any more — turning sources back on is per source.")
            }
        }
        .navigationTitle(Text("External Sources"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func title(for group: ExternalSourceGroup) -> LocalizedStringKey {
        switch group {
        case .catalogs: "Catalogs"
        case .directories: "Directories"
        case .enrichment: "Images, Logos & Lyrics"
        }
    }

    private static func footer(for group: ExternalSourceGroup) -> LocalizedStringKey? {
        switch group {
        case .catalogs:
            "These deliver something listenable. What you started stays yours: a source off affects new requests only, never your library."
        case .directories:
            // The Apple transparency line survives the old network page
            // verbatim: what Apple sees, and what it never does.
            "Directories only help finding things. Apple sees search terms, genre numbers and your storefront country (plus standard request data like your IP address) — never an account, never your subscriptions, never a listening profile; all queries are derived on this device."
        case .enrichment:
            "Only trimmings. None of these services requires an account; requests carry no identifiers beyond the query itself."
        }
    }
}

/// One source: switch, effect line, the rows it feeds, and the derived
/// reason when the cleanup rule (or the user) left it off with no
/// visible row asking. No stored state: the reason is readable from the
/// two questions themselves.
private struct SourceToggleRow: View {
    let source: ExternalSource
    @AppStorage private var allowed: Bool
    @AppStorage(AppStorageKeys.jamendoClientId) private var jamendoClientId = ""

    init(source: ExternalSource) {
        self.source = source
        _allowed = AppStorage(wrappedValue: true, source.storageKey)
    }

    /// PodcastIndex is only ever asked with a configured key. Without one
    /// the row states that instead of showing a switch that switches
    /// nothing.
    private var lacksKey: Bool {
        source.key == "podcastIndex" && !AppStorageKeys.podcastIndexConfigured
    }

    private var fedRows: [AppRow] { AppRows.rows(feeding: source.key) }

    private var fedLine: String? {
        let titles = fedRows.map(\.title)
        guard !titles.isEmpty else { return nil }
        return String(localized: "Feeds: \(titles.joined(separator: " · "))")
    }

    /// Off, and no visible row asks any more: the state the cleanup rule
    /// produces, named where it shows.
    private var unusedReason: Bool {
        !allowed && !fedRows.isEmpty
            && !fedRows.contains { AppRows.isVisible($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if lacksKey {
                Text(verbatim: source.title)
                Text("Not asked: no key configured. Enter your own key on the podcast source page.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                AppSwitch(isOn: $allowed) { Text(verbatim: source.title) }
                    .accessibilityIdentifier("source-toggle-\(source.key)")
                Text(verbatim: source.effectLine)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let fedLine {
                Text(verbatim: fedLine)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if unusedReason {
                Text("Off — no visible row uses this source.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if source.key == "jamendo", allowed {
                TextField("Own Jamendo client_id (optional)", text: $jamendoClientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption)
            }
        }
    }
}
