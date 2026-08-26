// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Small floating activity pill shown while a background reload runs with
/// content already on screen. Pull-to-refresh returns early by design, so
/// without this the sync would be invisible.
struct RefreshActivityPill: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .padding(10)
            .modifier(AdaptiveGlassBackground(shape: Circle()))
            .padding(.top, 6)
            .transition(.opacity)
            .allowsHitTesting(false)
    }
}
