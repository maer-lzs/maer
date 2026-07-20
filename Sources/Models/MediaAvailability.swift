// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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
}
