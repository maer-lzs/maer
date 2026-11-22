// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The drawn cover of a Musopen recording, which has no picture: a field
/// whose colour belongs to the composer, with the composer and the work
/// on it in white (`MusopenCover`). The tile, the page and the player draw
/// the same cover.
nonisolated enum MusopenCoverArt {
    /// Twelve colours as red, green and blue; white text reaches 4.5:1 on
    /// each.
    static let palette: [[Double]] = [
        [0.62, 0.16, 0.20], [0.62, 0.30, 0.08], [0.50, 0.38, 0.06], [0.33, 0.42, 0.12],
        [0.12, 0.42, 0.24], [0.05, 0.40, 0.42], [0.08, 0.33, 0.52], [0.16, 0.25, 0.62],
        [0.30, 0.20, 0.60], [0.45, 0.18, 0.55], [0.55, 0.15, 0.40], [0.28, 0.32, 0.38],
    ]

    static func applies(to itemId: String) -> Bool { itemId.hasPrefix(MusopenCatalog.prefix) }

    /// The composer's place in the palette: FNV-1a over the name, trimmed,
    /// in lower case and in its composed form. A hash of its own, because
    /// the one of the standard library changes with every launch, and the
    /// colour must not.
    static func colourIndex(composer: String?) -> Int {
        let name = (composer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().precomposedStringWithCanonicalMapping
        guard !name.isEmpty else { return 0 }
        var hash: UInt32 = 0x811c9dc5
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return Int(hash % UInt32(palette.count))
    }

    static func colour(composer: String?) -> [Double] { palette[colourIndex(composer: composer)] }

    /// The composer above the work; a name of blanks is no composer.
    static func lines(title: String, composer: String?) -> (composer: String?, work: String) {
        let name = composer?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false ? name : nil, title)
    }
}
