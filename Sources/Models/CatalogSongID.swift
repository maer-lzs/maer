// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A single track of an archive.org release, addressable on its own:
/// `lva:<identifier>#<index>`.
///
/// Without an address of its own, a track exists only as a time offset inside
/// one long item — so a release of fifteen songs is one work with fifteen
/// chapters. It cannot go into a playlist, it has no position of its own, and
/// "played" applies to the whole album.
///
/// The suffix rides on the EXISTING namespace on purpose: `lva:x#3` still
/// starts with `lva:`, so the provider routing and the media family keep
/// working unchanged. Nothing else in the app has to learn a new prefix.
nonisolated enum CatalogSongID {
    static let separator: Character = "#"

    /// The address of one track. Index is the position in the release's track
    /// list, which is also how the downloaded file is addressed.
    static func make(album itemId: String, index: Int) -> String {
        "\(itemId)\(separator)\(index)"
    }

    /// Splits a song address back into release and index. Returns nil for a
    /// plain release id — the caller then means the whole thing.
    static func parse(_ id: String) -> (album: String, index: Int)? {
        guard let hash = id.lastIndex(of: separator) else { return nil }
        let indexPart = id[id.index(after: hash)...]
        guard let index = Int(indexPart), index >= 0 else { return nil }
        return (String(id[..<hash]), index)
    }

    /// The release an id belongs to — itself when it is not a song address.
    static func album(of id: String) -> String {
        parse(id)?.album ?? id
    }

    static func isSong(_ id: String) -> Bool { parse(id) != nil }
}
