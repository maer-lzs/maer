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

    /// The composer's place in the palette: FNV-1a over the family name in
    /// lower case and in its composed form. The source names one composer
    /// as "Mozart", "Wolfgang Amadeus Mozart" or "Mozart, Wolfgang Amadeus";
    /// the family name is the part before a comma, else the last word. A
    /// hash of its own, because the one of the standard library changes
    /// with every launch, and the colour must not.
    static func colourIndex(composer: String?) -> Int {
        Int(familyHash(composer) % UInt32(palette.count))
    }

    /// FNV-1a over the family name; no name hashes to 0.
    private static func familyHash(_ composer: String?) -> UInt32 {
        let name = familyName(composer).lowercased().precomposedStringWithCanonicalMapping
        guard !name.isEmpty else { return 0 }
        var hash: UInt32 = 0x811c9dc5
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return hash
    }

    static func familyName(_ composer: String?) -> String {
        var name = (composer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = name.firstIndex(of: ",") { name = String(name[..<comma]) }
        return name.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
    }

    static func colour(composer: String?) -> [Double] { palette[colourIndex(composer: composer)] }

    /// The composer above the work. The composer is the one the page's
    /// order sorts by (`MusopenOrder.composer`), so a field that is no name
    /// does not stand on the cover nor give it its colour and letter; the
    /// work is the whole title.
    static func lines(title: String, composer: String?) -> (composer: String?, work: String) {
        (MusopenOrder.composer(author: composer, title: title), title)
    }

    /// The two colours of the diagonal, both from the hash of the family
    /// name: the first as `colourIndex`, the second from the rest of the
    /// hash among the other eleven, so they never match.
    static func colourIndices(composer: String?) -> (start: Int, end: Int) {
        let hash = familyHash(composer)
        let count = UInt32(palette.count)
        let start = Int(hash % count)
        let step = Int((hash / count) % (count - 1)) + 1
        return (start, (start + step) % palette.count)
    }

    static func colours(composer: String?) -> (start: [Double], end: [Double]) {
        let pair = colourIndices(composer: composer)
        return (palette[pair.start], palette[pair.end])
    }

    /// The colour at `t` along the diagonal, as the gradient blends it.
    static func mix(_ start: [Double], _ end: [Double], at t: Double) -> [Double] {
        zip(start, end).map { $0 * (1 - t) + $1 * t }
    }

    /// The initial is a darker shade of the field: a dark letter can only
    /// raise the contrast of the white text over it.
    static let letterShade: Double = 0
    static let letterOpacity: Double = 0.22

    static func underLetter(_ rgb: [Double]) -> [Double] {
        rgb.map { $0 * (1 - letterOpacity) + letterShade * letterOpacity }
    }

    /// The first letter of the family name, else of the work.
    static func initial(composer: String?, title: String) -> String {
        let name = familyName(composer)
        let source = name.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : name
        return source.first.map { String($0).uppercased() } ?? ""
    }
}
