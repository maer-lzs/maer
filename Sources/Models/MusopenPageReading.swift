// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The reading of the Musopen page as a value: what it holds, where the
/// next answer starts and whether the last one failed. The page's order
/// needs every recording, so the page reads every answer when it opens
/// (about seventeen) and shows what it has after each one. The fetch is
/// handed in, so the run itself has its witness.
@MainActor
struct MusopenPageReading {
    typealias Answer = (outcome: CatalogLoadOutcome, next: MusopenCatalog.Cursor?)

    var items: [LibraryItem] = []
    /// Where the next answer starts; nil once every category is read.
    var cursor: MusopenCatalog.Cursor? = MusopenCatalog.Cursor()
    var failed = false

    /// A failure below rows already read stands as a line with its retry
    /// at the end of the list; with nothing read, the page itself fails.
    var showsFailedLine: Bool { failed && !items.isEmpty }

    /// Whether the page reads when it appears: while its reading is open
    /// and not failed. A page left in the middle of the reading (its task
    /// ends with the page) reads on from where it stood when it appears
    /// again; a failure waits for Try Again, a page read to its end reads
    /// nothing more.
    var readsOnAppear: Bool { cursor != nil && !failed }

    /// Every answer in turn from where the reading stands, until the end,
    /// a failure or a reader that no longer moves. A failure kept from
    /// before is cleared first: this is also "Try Again", which reads on
    /// from where it stood. `show` gets the state after every answer.
    static func readAll(_ start: Self, fetch: (MusopenCatalog.Cursor) async -> Answer,
                        show: (Self) -> Void) async -> Self {
        var state = start
        state.failed = false
        while state.cursor != nil, !state.failed, !Task.isCancelled {
            let before = state.cursor
            state = await state.nextAnswer(fetch)
            show(state)
            if state.cursor == before { break }
        }
        return state
    }

    /// The next answer. One whose files all stay out is read past, a few
    /// at most, so every step brings recordings when there are any
    /// further on; an answer that points back where it was read from ends
    /// the step.
    func nextAnswer(_ fetch: (MusopenCatalog.Cursor) async -> Answer) async -> Self {
        var state = self
        guard var from = state.cursor else { return state }
        for _ in 0..<3 {
            let answer = await fetch(from)
            switch answer.outcome {
            case .loaded(let found, _):
                state.failed = false
                let known = Set(state.items.map(\.id))
                state.items += found.filter { !known.contains($0.id) }
                state.cursor = answer.next
                guard found.isEmpty, let next = answer.next, next != from else { return state }
                from = next
            case .failed:
                state.failed = true
                return state
            case .cancelled:
                return state
            }
        }
        return state
    }
}
