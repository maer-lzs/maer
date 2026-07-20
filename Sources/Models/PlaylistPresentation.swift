// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// F5: pure, testable presentation rules for the music-tab playlist cards —
/// the 2×2 mosaic degradation, the metadata line's duration, and the
/// "recently changed first" sort key. Foundation-only.
nonisolated enum PlaylistPresentation {
    /// How many mosaic tiles to render for the available cover count (graceful
    /// degradation): 0 → 0 (the glyph placeholder), 1 → 1 (fills), 2 → 2, 3 → 3
    /// (rendered 2+1), 4 or more → a full 2×2.
    static func mosaicTileCount(_ coverCount: Int) -> Int {
        min(max(coverCount, 0), 4)
    }

    /// Total playlist duration → "1:12" (H:MM) when at least an hour, else
    /// "3:45" (M:SS). Used in the metadata pill "18 Titel · 1:12".
    static func durationText(seconds: Int) -> String {
        let s = max(seconds, 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d", h, m) : String(format: "%d:%02d", m, sec)
    }

    /// ISO-8601 `changed` timestamp → Date for the sort; nil when absent/unparsable.
    static func changedDate(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return isoFractional.date(from: iso) ?? isoPlain.date(from: iso)
    }

    /// Sort playlists newest-changed first; ones without a timestamp sort last,
    /// then stably by their existing order (index tiebreak).
    static func sortedByChanged<T>(_ items: [T], changed: (T) -> Date?) -> [T] {
        items.enumerated().sorted { a, b in
            switch (changed(a.element), changed(b.element)) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x > y
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    // `nonisolated(unsafe)`: ISO8601DateFormatter isn't Sendable, but these are
    // configured once and only ever READ (date parsing) — the project's
    // established pattern for shared formatters.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()
}
