// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The two folds of the subscriptions: whether the Pinchflat mirror's
/// shows and the premium feeds stand in the subscriptions like any feed
/// (with their glyph, counted with them) or in their own rows. The rule
/// itself is `SubscriptionFold`; this page only writes its two choices.
/// The Pinchflat switch stands only with a Pinchflat server: without one
/// it would switch nothing.
struct PodcastSubscriptionFoldSection: View {
    @AppStorage(AppStorageKeys.podcastsPinchflatInSubscriptions) private var pinchflatFolded = false
    @AppStorage(AppStorageKeys.podcastsPremiumInSubscriptions) private var premiumFolded = false

    /// Each switch has its own footer, so the sentence names the shows it
    /// moves.
    var body: some View {
        if PinchflatClient.isConfigured(PinchflatClient.serverURL) {
            Section {
                AppSwitch(isOn: $pinchflatFolded) {
                    Label("Pinchflat like other feeds", systemImage: PinchflatGlyph.symbol)
                }
                .accessibilityIdentifier("fold-pinchflat")
            } header: {
                Text("Subscriptions")
            } footer: {
                Text("If switched on, Pinchflat shows will be displayed with your other subscriptions and count alongside them. Their own row will no longer be shown.")
            }
        }
        Section {
            AppSwitch(isOn: $premiumFolded) {
                Label("Premium like other feeds", systemImage: "lock.fill")
            }
            .accessibilityIdentifier("fold-premium")
        } header: {
            if !PinchflatClient.isConfigured(PinchflatClient.serverURL) { Text("Subscriptions") }
        } footer: {
            Text("If switched on, premium shows will be displayed with your other subscriptions and count alongside them. Their own row will no longer be shown.")
        }
    }
}
