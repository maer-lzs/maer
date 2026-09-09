// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The ONE place that shows „this feed brought no episodes".
///
/// There are three ways to subscribe (the podcast settings page, the subscribe
/// button on cards and show pages, the catalog page), and they are not one
/// action: only the middle one does the full work. Hosting the message here,
/// once, means the sentence exists once no matter which way was taken. The
/// store raises it (`PodcastSubscriptions.emptyFeedNotice`), because the store
/// is the only place that knows what the parse yielded.
///
/// Hosted in `RootView` beside `playlistDialogs()`, the established seat for
/// something that belongs to no single screen.
private struct PodcastSubscribeNoticeHost: ViewModifier {
    @ObservedObject private var subs = PodcastSubscriptions.shared

    func body(content: Content) -> some View {
        content.alert(
            // The show's name is the headline, so the person sees WHICH feed
            // is meant. The subscription happened: that is why the sentence
            // says „Subscribed" first and does not offer to undo anything.
            Text(subs.emptyFeedNotice ?? ""),
            isPresented: Binding(get: { subs.emptyFeedNotice != nil },
                                 set: { if !$0 { subs.emptyFeedNotice = nil } })
        ) {
            Button("OK", role: .cancel) { subs.emptyFeedNotice = nil }
        } message: {
            Text("Subscribed. This feed has no episodes yet.")
        }
    }
}

extension View {
    /// See `PodcastSubscribeNoticeHost`. Belongs exactly once into the app's
    /// root, like the playlist dialogs.
    func podcastSubscribeNotice() -> some View {
        modifier(PodcastSubscribeNoticeHost())
    }
}
