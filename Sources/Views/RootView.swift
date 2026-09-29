// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

struct RootView: View {
    /// Process-wide session (see AppSession): the same instances are also used
    /// by the CarPlay scene.
    private static let session = AppSession.shared
    @ObservedObject private var authViewModel = Self.session.authViewModel
    /// "start without a server". The app is fully usable podcasts-first;
    /// ABS (and every other source) attaches later in the settings. No forced
    /// login wall: logging out in serverless mode stays in the app.
    @AppStorage(AppStorageKeys.serverlessMode) private var serverless = false
    /// "Next steps" after the first success: the card returns at every
    /// start until it is dismissed; the dismissal is what gets stored.
    @AppStorage(AppStorageKeys.nextStepsDismissed) private var nextStepsDismissed = false
    @State private var showNextSteps = false
    /// The ONE observer of the network watch for the whole UI. It hands the
    /// answer down as `\.isOnline` so no surface below has to subscribe
    /// itself. It sits HERE and not at the library, because the root also
    /// presents sheets of its own (next steps, the playlist dialogs), and
    /// those hang beside the library, not inside it.
    ///
    /// Observing at the outermost view invalidates everything below on every
    /// change, which is the shape this project avoids. It is allowed here
    /// because a network change never happens during a gesture, and it stays
    /// allowed only while the monitor publishes this one answer and nothing
    /// else. A fence holds that condition.
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    private var unlocked: Bool { authViewModel.isLoggedIn || serverless }

    /// The seed exists in Debug only; a Release build has no harness.
    private static var isHarness: Bool {
        #if DEBUG
        UITestSeed.isHarness
        #else
        false
        #endif
    }

    /// The bookmark measurement for linked folders resolves once per launch; debug
    /// builds only, a Release build does nothing here.
    private static func measureOnLaunch() {
        #if DEBUG
        BookmarkMeasure.resolveOnLaunch()
        #endif
    }

    var body: some View {
        Group {
            if unlocked {
                LibraryView(provider: authViewModel.apiClient, onLogout: authViewModel.logout)
            } else {
                SetupView(viewModel: authViewModel)
            }
        }
        // The harness never sees the card: a journey starts on the tab it
        // asked for, not behind a sheet.
        .task(id: unlocked) {
            if unlocked, !nextStepsDismissed, !Self.isHarness { showNextSteps = true }
        }
        .task { Self.measureOnLaunch() }
        .sheet(isPresented: $showNextSteps, onDismiss: { nextStepsDismissed = true }) {
            NextStepsSheet(authViewModel: authViewModel, coordinator: Self.session.playerCoordinator)
                .followsAppearanceChoice()
        }
        // The playlist dialogs belong HERE and nowhere else: they are
        // triggered from context menus whose hierarchy is torn down on close,
        // so an alert attached there can never be presented. At the root it
        // survives, and every call site shares this one presentation.
        .playlistDialogs()
        // One seat for „this feed brought no episodes", because there are
        // three ways to subscribe and the sentence must exist once.
        .podcastSubscribeNotice()
        // OUTERMOST on purpose: every sheet and dialog of this root is
        // attached above, and only a value set out here reaches into them
        // as well as into the tabs and their pushed pages.
        .environment(\.isOnline, networkMonitor.isConnected)
    }
}
