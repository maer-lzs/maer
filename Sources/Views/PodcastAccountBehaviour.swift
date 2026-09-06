// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// What an ACCOUNT does for podcasts. Shown at Podcasts, named after the
/// account.
///
/// The line this draws is the design work, and the order names it: the account
/// page keeps address, access and MODES (which types an account serves at
/// all); what an account does *for a type* belongs to that type. So "use
/// Audiobookshelf for podcasts" stays a mode on the account page, while
/// "subscribe on the server". Which only means anything once podcasts are on.
/// Lives here.
///
/// The section header is the account's own name, because that is the link: the
/// same word under Podcasts and under Audiobooks is how one recognises one
/// account instead of two.
struct PodcastAccountBehaviour: View {
    @AppStorage(AppStorageKeys.absPodcastsEnabled) private var absPodcastsEnabled = false
    @AppStorage(AppStorageKeys.podcastSubscribeToServer) private var subscribeToServer = true
    @AppStorage(AppStorageKeys.podcastAutoSaveOnPlay) private var autoSaveOnPlay = true
    // Default ON (D12): both devices share ONE subscription list, premium
    // feeds included. A device that turned it off deliberately keeps its
    // stored value, which wins over the default.
    @AppStorage(AppStorageKeys.gpodderSyncsPremiumFeeds) private var syncsPremium = true
    @AppStorage(AppStorageKeys.gpodderEnabled) private var gpodderEnabled = false
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared

    var body: some View {
        // A section only where the account actually acts. An account that
        // does not serve podcasts has no podcast behaviour to show, and an
        // empty section would be a promise without a referent.
        if absPodcastsEnabled && absPodcast.hasPodcasts {
            Section {
                AppSwitch(isOn: $subscribeToServer) {
                    Label("Subscribe on server", systemImage: "cloud")
                }
                .accessibilityIdentifier("podcast-abs-subscribe-on-server")
                AppSwitch(isOn: $autoSaveOnPlay) {
                    Label("Auto-save to server on play", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("podcast-abs-autosave")
            } header: {
                Text(verbatim: "Audiobookshelf")
            } footer: {
                Text("New subscriptions are created on your Audiobookshelf server and sync across devices. Off = local only, this device. Auto-save stores a streamed feed episode on the server after ~30 s so its progress syncs there too.")
            }
        }
        if gpodderEnabled {
            Section {
                AppSwitch(isOn: $syncsPremium) {
                    Label("Sync premium feeds", systemImage: "key")
                }
                .accessibilityIdentifier("podcast-gpodder-premium")
                // The kick travels WITH the switch: flipping it either way
                // starts a reconcile, because otherwise one waits on an
                // invisible timer and reads the feature as broken. Leaving it
                // behind on the account page would have been the quiet half of
                // this move.
                .onChange(of: syncsPremium) {
                    Task { await GPodderSync.shared.reconcile() }
                }
            } header: {
                Text(verbatim: "gpodder")
            } footer: {
                Text("Premium feeds carry access data in their address. Off keeps them on this device only; mirrors stay out either way.")
            }
        }
    }
}
