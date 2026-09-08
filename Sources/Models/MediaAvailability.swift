// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The canonical "offline-unavailable" rule for downloadable server media
/// (audiobooks, podcast episodes, music): a title that is neither reachable
/// (no network) nor on the device (not downloaded) can't play, so its row/tile
/// dims and carries the white wifi.slash glyph (A3). One pure place so every
/// MediaRowContent surface reads the same (Y60). Radio is NOT downloadable and
/// uses a plain `!isConnected` instead.
nonisolated enum MediaAvailability {
    static func offlineUnavailable(isConnected: Bool, isDownloaded: Bool) -> Bool {
        !isConnected && !isDownloaded
    }

    /// The SAME fact, said the other way round, for the paths that gate
    /// PLAYING instead of dimming.
    ///
    /// It exists because the negative form had a name and the positive one
    /// did not, so eight call sites spelled it out by hand: `!offline ||
    /// isDownloaded`, `online || isDownloaded`, `isOnline ||
    /// isDownloaded`, `!isOffline || isDownloaded`. They all agreed when
    /// this was written, which is luck and not a guarantee: a title that
    /// dims as unplayable while a menu still offers Play is one wrong
    /// spelling away, and nothing would have caught it.
    ///
    /// Defined AS the negation, so the display side and the play side
    /// cannot disagree by construction. A play gate reading „not
    /// offline-unavailable" would be a double negative at every call site,
    /// which is why this has its own name instead.
    static func canPlayNow(isConnected: Bool, isDownloaded: Bool) -> Bool {
        !offlineUnavailable(isConnected: isConnected, isDownloaded: isDownloaded)
    }
}
