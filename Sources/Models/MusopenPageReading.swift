// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The reading of the Musopen page as a value: what it holds, where the
/// next answer starts and whether the last one failed.
@MainActor
struct MusopenPageReading {
    typealias Answer = (outcome: CatalogLoadOutcome, next: MusopenCatalog.Cursor?)

    var items: [LibraryItem] = []
    /// Where the next answer starts; nil once every category is read.
    var cursor: MusopenCatalog.Cursor? = MusopenCatalog.Cursor()
    var failed = false

    /// Whether a failure stands below rows already read.
    var showsFailedLine: Bool { false }

    static func readAll(_ start: Self, fetch: (MusopenCatalog.Cursor) async -> Answer,
                        show: (Self) -> Void) async -> Self {
        var state = start
        while state.cursor != nil, !state.failed, !Task.isCancelled {
            let before = state.cursor
            state = await state.nextAnswer(fetch)
            show(state)
            if state.cursor == before { break }
        }
        return state
    }

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
                guard found.isEmpty, let next = answer.next else { return state }
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
