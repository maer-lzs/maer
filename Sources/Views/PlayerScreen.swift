// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// What the full player shows, pure. A spinner only while something IS
/// loading. With no session, no load and no error there is nothing to show:
/// the mirror cleared a finished title (`STANDBY cleared live`) or the
/// advance found nothing, and the player used to spin forever over it.
nonisolated enum PlayerScreenContent: Equatable {
    case player
    /// A title change is loading and the screen has a session it showed:
    /// that one stays in place until the new one is ready, so the player
    /// does not drop to a spinner between two titles.
    case held
    case loading
    case error(String)
    case nothing

    static func of(hasSession: Bool, isLoading: Bool, loadError: String?,
                   holdsShown: Bool = false) -> PlayerScreenContent {
        if hasSession { return .player }
        if isLoading { return holdsShown ? .held : .loading }
        if let loadError { return .error(loadError) }
        return .nothing
    }
}

/// Shows the session currently running in the PlayerCoordinator as the full
/// player screen. Loads nothing itself anymore. The coordinator handles
/// loading so the same session stays visible from the mini-player bar too.
struct PlayerScreen: View {
    @Environment(\.itemRouter) private var router
    @ObservedObject var coordinator: PlayerCoordinator
    /// The feed cover of a LibriVox book once resolved, by id.
    @State private var feedCovers: [String: URL] = [:]
    /// Passed through from the overlay presentation (drag-to-dismiss).
    var dragProgress: CGFloat = 0
    /// Corner radius of the overlay sheet. Passed through to PlayerView.
    var cornerRadius: CGFloat = 0
    /// Explicit safe area insets (the root ignores the safe areas).
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    /// The session this screen showed last. The coordinator drops its model
    /// while a title change loads; the screen keeps this one in place,
    /// taking no input of any kind, until the new one is ready. Its title
    /// stays with it.
    @State private var shown: ShownSession?

    struct ShownSession {
        let viewModel: PlayerViewModel
        let item: LibraryItem
    }

    private var content: PlayerScreenContent {
        coordinator.screenContent(holdsShown: shown != nil)
    }

    var body: some View {
        Group {
            switch content {
            case .player, .held:
                // One branch for both: the old title goes straight over to
                // the new one when it is ready, never through a spinner. The
                // view is keyed by its model, so each title starts with fresh
                // state of its own, as before.
                if let session = displayed {
                    player(session.viewModel, session.item)
                        .id(ObjectIdentifier(session.viewModel))
                        .takesInput(content == .player)
                        .task(id: ObjectIdentifier(session.viewModel)) {
                            if content == .player { shown = session }
                        }
                }
            case .loading:
                ProgressView("Loading…")
            case .error(let error):
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center)
                }
                .padding()
                .onAppear { shown = nil }
            case .nothing:
                // Said for the moment the overlay needs to close itself.
                Text("Nothing is playing.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("player-nothing-playing")
                    .onAppear { shown = nil }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    /// The title over the screen: the held session's while it stands in.
    private var title: String {
        let item = content == .held ? shown?.item : coordinator.activeItem
        return item?.title ?? ""
    }

    /// The session on screen: the running one, or while a title change
    /// loads, the one shown before it.
    private var displayed: ShownSession? {
        if content == .held { return shown }
        guard let viewModel = coordinator.viewModel, let item = coordinator.activeItem else { return nil }
        return ShownSession(viewModel: viewModel, item: item)
    }

    private func player(_ viewModel: PlayerViewModel, _ item: LibraryItem) -> some View {
        PlayerView(
            viewModel: viewModel,
            coordinator: coordinator,
            coverURL: feedCovers[item.id] ?? router.largeCoverURL(item.id),
            dragProgress: dragProgress,
            cornerRadius: cornerRadius,
            topInset: topInset,
            bottomInset: bottomInset
        )
        .task(id: item.id) {
            // A LibriVox book shows the cover its page shows, the feed's.
            if let feed = await LibriVoxCoverLoader.hiresCover(forItemId: item.id) { feedCovers[item.id] = feed }
        }
    }
}

extension PlayerCoordinator {
    /// The full player's content, asked by the screen and by the overlay
    /// that closes itself on `.nothing`.
    var screenContent: PlayerScreenContent { screenContent(holdsShown: false) }

    /// The same for a view that showed a session: it holds that one while a
    /// title is on its way. The full player and the mini player ask here.
    func screenContent(holdsShown: Bool) -> PlayerScreenContent {
        PlayerScreenContent.of(hasSession: viewModel != nil && activeItem != nil,
                               isLoading: isChangingTitle, loadError: loadError, holdsShown: holdsShown)
    }
}
