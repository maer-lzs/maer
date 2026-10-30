// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The app's side of the rows of the large and medium "Continue": which
/// source a title belongs to, and the rows of one pass of the home page.
/// Pure; which rows a new title replaces and what the widget shows of them
/// is `WidgetRows`, shared with the widget.
nonisolated enum ContinueBySource {
    /// The source of a title is its tab, by the app's one assignment
    /// (`MediaFamily.kind(for:markedForm:)`): a catalogue album is music, a
    /// reading an audiobook. Nil for an id no family knows.
    static func source(for id: String, markedForm: ProgressMark.StartedForm? = nil) -> WidgetSource? {
        MediaFamily.kind(for: id, markedForm: markedForm).flatMap { WidgetSource(rawValue: $0.rawValue) }
    }

    /// The rows after a change of sources, without waiting for a home pass
    /// that may not come: the rows whose title's source is still available
    /// stay, the others go. The moment of the pass stays too, so a title
    /// heard after it still joins; only when the snapshot's own title lost
    /// its source does the moment become `nowMs`, so it stays out as well.
    static func keepingAvailable(_ stored: ContinueRows?, snapshotItemId: String?, nowMs: Double,
                                 isAvailable: (String) -> Bool) -> (rows: [WidgetSourceRow], passAtMs: Double) {
        let rows = (stored?.rows ?? []).filter { isAvailable($0.itemId) }
        let snapshotGone = snapshotItemId.map { !isAvailable($0) } ?? false
        return (rows, snapshotGone ? nowMs : (stored?.passAtMs ?? nowMs))
    }

    /// What the home page knows of one title of its rows.
    struct Card: Equatable {
        var title: String
        var subtitle: String?
        var kindSymbol: String
        var markedForm: ProgressMark.StartedForm?
        var isLive: Bool
        /// The progress on this device and the one the server reports.
        var local: BookProgress?
        var server: BookProgress?
        var duration: Double?
    }

    /// The newer of the device's and the server's progress, nil when
    /// neither is known.
    static func progress(of card: Card) -> BookProgress? {
        [card.local, card.server].compactMap { $0 }.max { $0.lastUpdate < $1.lastUpdate }
    }

    /// The rows of one pass of the home page: every title its "Continue"
    /// and "Listen Again" show, with its moment in milliseconds, a row each,
    /// of which `WidgetRows.merged` keeps what a widget can show. The home
    /// page has already left out what it does not show (finished, hidden);
    /// nothing of an earlier pass stays, so a title the home page no longer
    /// shows (its server removed, another account) leaves the rows.
    static func rows(of moments: [(id: String, ms: Double)], card: (String) -> Card?) -> [WidgetSourceRow] {
        var rows: [WidgetSourceRow] = []
        for moment in moments {
            guard let card = card(moment.id),
                  let source = source(for: moment.id, markedForm: card.markedForm) else { continue }
            let progress = card.isLive ? nil : progress(of: card)
            let length = card.duration ?? 0
            let left = progress.flatMap { done -> Double? in
                guard length > 0 else { return nil }
                return max(length - (done.currentTime ?? done.fraction * length), 0)
            }
            let row = WidgetSourceRow(source: source, itemId: moment.id, title: card.title, subtitle: card.subtitle,
                                      fraction: progress?.fraction, remainingText: left.map(DurationText.remaining(seconds:)),
                                      isLive: card.isLive, kindSymbol: card.kindSymbol,
                                      cover: WidgetCoverStore.continueRows.name(for: moment.id), playedAt: moment.ms)
            rows = WidgetRows.merged(row, into: rows)
        }
        return rows
    }
}
