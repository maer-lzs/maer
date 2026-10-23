// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the playback bar offers beyond play and AirPlay, by medium, once it
/// is wide (from a 600 pt window: the full controls of each medium in the
/// one bar). A narrow bar keeps its own small set.
nonisolated enum PlaybackBarControls {
    enum Control: Hashable, Sendable {
        /// The title way back and forward: a chapter for a book or episode,
        /// a song for music (the full player's `stepTitle`).
        case titleBack, titleForward
        case skipBack, skipForward
        case speed, sleepTimer, queue
    }

    /// A 600 pt window minus the bar's margins at both sides.
    static let wideFromBarWidth: CGFloat = 580

    static func isWide(barWidth: CGFloat) -> Bool { barWidth >= wideFromBarWidth }

    /// The extra controls of a wide bar, in their order before AirPlay and
    /// play. A live stream has nothing to step or skip into.
    static func wide(isLive: Bool, isMusic: Bool) -> [Control] {
        if isLive { return [] }
        if isMusic { return [.titleBack, .titleForward, .queue] }
        return [.titleBack, .skipBack, .skipForward, .titleForward, .speed, .sleepTimer]
    }
}
