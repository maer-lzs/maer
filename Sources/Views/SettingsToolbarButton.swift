// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Environment action to open the app settings sheet. Provided by
/// LibraryView ON the NavigationStack itself (like `pushPodcastRoute`), so
/// PUSHED detail pages can host the settings cog too. The ROOT toolbar's cog
/// does not propagate onto pushed views, so a detail page that adds its own
/// trailing actions (music album, podcast show) would otherwise show its actions
/// with NO cog beside them.
nonisolated struct OpenSettingsKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    var openSettings: @MainActor () -> Void {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

/// The settings cog for DETAIL pages that carry their own trailing toolbar
/// actions. Placed OUTERMOST so the page's actions sit inboard and the cog
/// stays visible (it never "vanishes behind" download/favorite). Detail pages
/// keep the system toolbar, so a plain gearshape picks up the system glass, in
/// line with the other system-toolbar buttons there.
struct SettingsToolbarButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel(Text("Settings"))
        .accessibilityIdentifier("open-settings")
    }
}
