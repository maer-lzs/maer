// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The part and the place in it of a Gutenberg work whose durations are
/// estimated. A stand counted over estimated durations must not travel, but
/// the part (a file) and the time in it are no estimate: they stay on this
/// device, so a failed read behind does not lose two hours of listening.
/// One row per title in its own table of the person's database; no carrier,
/// no sync and no swap reads it. When the real durations come, the place
/// becomes a stand and goes; a real stand of the title goes first.
@MainActor
final class EstimatedPlace {
    struct Place: Equatable, Sendable {
        let track: Int
        let offset: Double
    }

    private let keeper: RowKeeper<[Double]>?
    private var places: [String: [Double]] = [:]

    /// `database` nil keeps the places in memory only.
    init(database: MaerDatabase?) {
        keeper = database.map { RowKeeper(database: $0, table: .estimatedPlace, label: "ESTIMATEDPLACE") }
        guard let keeper else { return }
        places = keeper.startNow() ?? [:]
        // Rows read after a failed start count only while this run has
        // none of its own.
        keeper.adopt = { [weak self] rows in
            guard let self, self.places.isEmpty else { return }
            self.places = rows
        }
    }

    func note(_ itemId: String, track: Int, offset: Double, atMs: Double) {
        let row = [Double(track), offset, atMs]
        guard places[itemId] != row else { return }
        places[itemId] = row
        save()
    }

    func place(_ itemId: String) -> Place? {
        guard let row = places[itemId], row.count >= 2, row[0] >= 0 else { return nil }
        return Place(track: Int(row[0]), offset: max(0, row[1]))
    }

    func drop(_ itemId: String) {
        guard places.removeValue(forKey: itemId) != nil else { return }
        save()
    }

    private func save() {
        keeper?.write(emptying: .allowed) { [weak self] in self?.places ?? [:] }
    }

    /// The start of the part plus the time in it, over the tracks as they
    /// are now (estimated or real: the part is the same file). A part that
    /// is not there gives the start of the book.
    static func position(of place: Place, tracks: [ABSAudioTrack]) -> Double {
        guard tracks.indices.contains(place.track) else { return 0 }
        return (tracks[place.track].startOffset ?? 0) + place.offset
    }
}
