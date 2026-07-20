// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Shared top inset and section spacing for the scrollable content of all three
/// media tabs (audiobooks / podcasts / music). One source of truth so the
/// pull-down and the gap above the first row sit identically everywhere —
/// Music was the reference.
enum TabContentLayout {
    static let topInset: CGFloat = 8
    static let sectionSpacing: CGFloat = 24
}

/// F5 Nachtrag (the owner 20.07., Gerät): the poster/tile card family is 10%
/// narrower so at least two cards fit side by side on the largest iPhone (17
/// Pro Max). ONE central home for the fixed card widths so they never drift per
/// surface (Regel 2 — the Featured card and the Recommended tile were each used
/// at two sizes). First step only — a device-loop CANDIDATE; the owner tunes the
/// exact factor on the device.
enum CardMetrics {
    /// Large "Featured" continue-cards — books AND podcasts share this, so the
    /// two never drift apart (235 → 211, ×0.9).
    static let featuredCardWidth: CGFloat = 211
    /// Discover / Recommended catalog tiles — Home AND the podcast tab, one size
    /// (was 140 / 132; now 126, ×0.9 of the larger).
    static let recommendationTileWidth: CGFloat = 126
    /// Music playlist poster card (150 → 135, ×0.9).
    static let playlistCardWidth: CGFloat = 135
}
