// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The titles the last server answer of one kind (books, Audiobookshelf
/// episodes) named as not finished, kept across starts. The progress of a
/// run lives in memory, so without this the first answer after a start has
/// nothing before it, and a title finished elsewhere while the app was
/// closed stays in Up Next. Each kind has its own table with one row, so
/// the book library and the episode provider never write over each other.
@MainActor
final class HeldUnfinished {
    enum Kind {
        case books, absEpisodes
    }

    private static let row = "ids"
    private let keeper: RowKeeper<[String]>?
    private(set) var held: Set<String> = []

    /// `database` nil keeps the set in memory only.
    init(database: MaerDatabase?, kind: Kind) {
        keeper = database.map {
            RowKeeper(database: $0, table: kind == .books ? .heldUnfinishedBooks : .heldUnfinishedEpisodes,
                      label: "HELDUNFINISHED")
        }
        guard let keeper else { return }
        held = Set(keeper.startNow()?[Self.row] ?? [])
        // A row read after a failed start counts only while this run has
        // no answer of its own.
        keeper.adopt = { [weak self] rows in
            guard let self, self.held.isEmpty else { return }
            self.held = Set(rows[Self.row] ?? [])
        }
    }

    /// The titles `after` finished that `before` or, for a title `before`
    /// does not name, the kept set held as not finished; the answer's own
    /// unfinished titles become the kept set.
    func adopt(before: [String: BookProgress], after: [String: BookProgress]) -> [String] {
        let finished = HeardElsewhere.newlyFinished(before: before, after: after, held: held)
        let next = HeardElsewhere.unfinished(after)
        guard next != held else { return finished }
        held = next
        keeper?.write(emptying: .allowed) { [weak self] in
            self.map { $0.held.isEmpty ? [:] : [Self.row: $0.held.sorted()] }
        }
        return finished
    }

    /// The server left the device: the first answer of the next server or
    /// account compares with nothing it held.
    func forget() {
        guard !held.isEmpty else { return }
        held = []
        keeper?.write(emptying: .allowed) { [weak self] in
            self.map { $0.held.isEmpty ? [:] : [Self.row: $0.held.sorted()] }
        }
    }

    /// Waits for every queued write of the row (tests).
    func awaitPendingWrites() async {
        await keeper?.awaitPendingWrites()
    }
}
