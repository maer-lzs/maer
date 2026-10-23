// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A state mark on a cover. All of them stand at the top right, one under
/// the other, in the order of the cases: what the tile is, whether one may
/// open it, whether it is here, what one did with it, the favourite, a
/// count. What one taps stands at the bottom right and is no mark.
nonisolated enum CoverGlyph: Int, CaseIterable, Comparable, Sendable {
    /// The kind of a tile in a mixed row.
    case kind
    /// Premium or refused.
    case lock
    /// Offline and not downloaded, downloaded, or a failed download: one of them.
    case availability
    /// The book is finished.
    case finished
    /// The favourite station.
    case favourite
    /// New episodes or the number in a series, in its own signal colour.
    case count

    static func < (lhs: CoverGlyph, rhs: CoverGlyph) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the availability mark of a cover says, if anything: a failed
/// download, else a stored title, else a title not available offline.
/// Nothing to say is no mark, so it takes no place in the stack.
nonisolated enum CoverAvailability: Equatable, Sendable {
    case failed
    case downloaded
    case offline

    static func of(failed: Bool, downloaded: Bool, unavailable: Bool) -> CoverAvailability? {
        if failed { return .failed }
        if downloaded { return .downloaded }
        return unavailable ? .offline : nil
    }
}

/// Which marks a cover shows and which it only says.
nonisolated enum CoverGlyphs {
    /// The marks in the order of the stack, as many as `room` shown, the
    /// rest hidden (the tile says them to VoiceOver). Availability is never
    /// the one hidden while there is room for a mark at all: a dimmed cover
    /// alone does not carry the state, so the marks above it give way.
    /// A mark given twice stands once.
    static func stack(_ present: [CoverGlyph], room: Int) -> (shown: [CoverGlyph], hidden: [CoverGlyph]) {
        let ordered = Array(Set(present)).sorted()
        let fits = min(max(room, 0), ordered.count)
        var shown = Array(ordered.prefix(fits))
        if fits > 0, ordered.contains(.availability), !shown.contains(.availability) {
            shown[fits - 1] = .availability
            shown.sort()
        }
        return (shown, ordered.filter { !shown.contains($0) })
    }

    /// The marks of a book cover: its kind in a mixed row, its availability
    /// when there is one to say, finished. An availability with nothing to
    /// say takes no place, so it never pushes the check out of the room.
    static func book(hasKind: Bool, availability: CoverAvailability?, finished: Bool) -> [CoverGlyph] {
        (hasKind ? [.kind] : []) + (availability == nil ? [] : [.availability]) + (finished ? [.finished] : [])
    }

    /// How many marks of `glyphSide` fit above the control at the bottom
    /// right (`cornerSide`) on a cover of `coverSide`. The corner is
    /// reserved even where a tile has no control, so a stack never runs
    /// into one. A cover not measured yet (nil) hides nothing, so no mark
    /// blinks in on the first frame; a measured side that is no number fits none.
    static func room(coverSide: Double?, glyphSide: Double, cornerSide: Double) -> Int {
        guard let coverSide else { return .max }
        guard coverSide.isFinite, glyphSide.isFinite, glyphSide > 0, cornerSide.isFinite else { return 0 }
        return max(0, Int(((coverSide - max(cornerSide, 0)) / glyphSide).rounded(.down)))
    }
}
