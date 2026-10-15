// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The smallest leaf that shows the running time: it observes the clock,
/// and only its content is drawn again every second, not the surface
/// around it.
struct PlaybackTimeReader<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        content(clock.time)
    }
}
