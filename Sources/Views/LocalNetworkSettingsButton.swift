// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit

/// The way to the settings under a server form's message, only when the
/// message is the refused local network (`LocalNetworkAccess.sentence`):
/// the app's page in Settings, where "Local Network" is switched on.
struct LocalNetworkSettingsButton: View {
    let message: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if message == LocalNetworkAccess.sentence, let url = URL(string: UIApplication.openSettingsURLString) {
            Button("Open Settings") { openURL(url) }
                .accessibilityIdentifier("local-network-settings")
        }
    }
}
