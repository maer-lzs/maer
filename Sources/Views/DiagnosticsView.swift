// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The ONE place for developer diagnostics. Born from a real miss: the
/// catalog-reload lever lived in the storage section, and its owner could
/// not find it there. Rule of sorting: levers that produce text or clear
/// derived state live HERE; diagnostics bound to a surface's own session
/// (the radio logo report reads what THIS session showed, the book
/// progress diagnosis reads THIS book) stay at their place, and this page
/// is the index that says where.
struct DiagnosticsView: View {
    /// What the derived-store lever cleared last. It says so instead of
    /// acting silently.
    @State private var clearedStores: String?

    var body: some View {
        Form {
            Section {
                // The debug lever for the DERIVED stores, so the cold state
                // is reachable by hand instead of once in 24 hours. It
                // touches NOTHING that belongs to the user; the boundary
                // stands as a list in `DerivedStores`, not in this label.
                Button {
                    let geleert = DerivedStores.clear()
                    clearedStores = geleert.isEmpty
                        ? String(localized: "Nothing to clear")
                        : geleert.joined(separator: " · ")
                } label: {
                    Label("Reload Catalog Data", systemImage: "arrow.clockwise.circle")
                }
                .accessibilityIdentifier("diagnostics-reload-catalog")
                if let clearedStores {
                    Text(verbatim: clearedStores)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Actions")
            } footer: {
                Text("Clears derived caches only (catalog stock, day shelves, resolved lookups). Nothing of yours is touched; the app refetches on the next visit.")
            }

            // The index of the diagnostics that live at their surface: they
            // measure what THAT place shows in THIS session, so moving them
            // here would change what they measure.
            Section {
                LabeledContent {
                    Text("Radio tab, below the catalog rows")
                } label: {
                    Text("Station logo & listening report")
                }
                LabeledContent {
                    Text("On every book detail page")
                } label: {
                    Text("Book progress diagnosis")
                }
                LabeledContent {
                    Text("Settings › Sync History")
                } label: {
                    Text("Sync runs & counters")
                }
            } header: {
                Text("Diagnostics at their place")
            } footer: {
                Text("These read what their surface currently shows; a copy here would measure something else.")
            }
        }
        .navigationTitle(Text("Diagnostics"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
