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
        case play
        case speed, sleepTimer, queue, airPlay
    }

    /// A 600 pt window minus the bar's margins at both sides.
    static let wideFromBarWidth: CGFloat = 580

    static func isWide(barWidth: CGFloat) -> Bool { barWidth >= wideFromBarWidth }

    /// The gap the wide bar sets between two groups.
    static let groupGap: CGFloat = 16

    /// The wide bar per medium, in its groups and in order, play always
    /// last and alone at the right edge: the title way and the skips, the
    /// tools with AirPlay, then play. A live stream has nothing to step,
    /// skip or speed up.
    static func wide(isLive: Bool, isMusic: Bool) -> [[Control]] {
        if isLive { return [[.airPlay], [.play]] }
        if isMusic { return [[.titleBack, .titleForward], [.queue, .airPlay], [.play]] }
        return [[.titleBack, .skipBack, .skipForward, .titleForward], [.speed, .sleepTimer, .airPlay], [.play]]
    }

    /// How wide the title may be in a bar that spans a fold: up to the
    /// fold, so every button stands right of it; nil without a fold inside
    /// the bar.
    static func titleWidth(barMinX: CGFloat, barWidth: CGFloat, fold: ClosedRange<CGFloat>?,
                           leadingPadding: CGFloat) -> CGFloat? {
        guard let fold, fold.lowerBound > barMinX, fold.upperBound < barMinX + barWidth else { return nil }
        return max(0, fold.lowerBound - barMinX - leadingPadding)
    }
}
