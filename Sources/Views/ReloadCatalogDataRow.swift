// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The lever for the DERIVED stores in the settings' storage section, so the
/// cold state is reachable by hand instead of once in 24 hours. It touches
/// NOTHING that belongs to the person; the boundary stands as a list in
/// `DerivedStores`, not in this label. It says what it cleared instead of
/// acting silently.
struct ReloadCatalogDataRow: View {
    @State private var clearedStores: String?

    var body: some View {
        Button {
            let cleared = DerivedStores.clear()
            clearedStores = cleared.isEmpty
                ? String(localized: "Nothing to clear")
                : cleared.joined(separator: " · ")
        } label: {
            Label("Reload Catalog Data", systemImage: "arrow.clockwise.circle")
        }
        .accessibilityIdentifier("diagnostics-reload-catalog")
        if let clearedStores {
            Text(verbatim: clearedStores)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
