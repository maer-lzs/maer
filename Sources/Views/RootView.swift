// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

struct RootView: View {
    /// Process-wide session (see AppSession): the same instances are also used
    /// by the CarPlay scene.
    @ObservedObject private var authViewModel = AppSession.shared.authViewModel
    /// "start without a server" — the app is fully usable podcasts-first;
    /// ABS (and every other source) attaches later in the settings. No forced
    /// login wall: logging out in serverless mode stays in the app.
    @AppStorage(AppStorageKeys.serverlessMode) private var serverless = false

    var body: some View {
        Group {
            if authViewModel.isLoggedIn || serverless {
                LibraryView(provider: authViewModel.apiClient, onLogout: authViewModel.logout)
            } else {
                SetupView(viewModel: authViewModel)
            }
        }
        // The playlist dialogs belong HERE and nowhere else: they are
        // triggered from context menus whose hierarchy is torn down on close,
        // so an alert attached there can never be presented. At the root it
        // survives, and every call site shares this one presentation.
        .playlistDialogs()
    }
}
