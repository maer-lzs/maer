// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine

/// The running time of playback, published on its own: the one value of
/// the player that changes every second. A surface that shows the time
/// observes this clock in its smallest leaf (`PlaybackTimeReader`, or an
/// `@ObservedObject` in a leaf that is small already); the player model
/// publishes only what changes rarely, so a surface that does not show the
/// time is not woken every second. Set by the model alone, when its
/// `currentTime` changes.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
}
