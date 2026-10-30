// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The rows the app keeps for the large and medium "Continue": which source
/// a title belongs to, which rows a new title replaces, and which rows go
/// because the app would no longer show their title. Pure; what the widget
/// shows of the rows is `WidgetRows`.
nonisolated enum ContinueBySource {
    /// How many titles the medium widget shows when it shows the titles
    /// heard last; the rows keep at least that many besides the newest of
    /// each source.
    static let recentKept = 2

    /// The source of a title is its tab, by the app's one assignment
    /// (`MediaFamily.kind(for:markedForm:)`): a catalogue album is music, a
    /// reading an audiobook. Nil for an id no family knows.
    static func source(for id: String, markedForm: ProgressMark.StartedForm? = nil) -> WidgetSource? {
        MediaFamily.kind(for: id, markedForm: markedForm).flatMap { WidgetSource(rawValue: $0.rawValue) }
    }

    /// The rows with `row` in them: its title once, and of the rest only
    /// what a widget can still show, the newest title of every source and
    /// the `recentKept` titles heard last.
    static func merged(_ row: WidgetSourceRow, into rows: [WidgetSourceRow]) -> [WidgetSourceRow] {
        let others: [WidgetSourceRow] = rows.filter { $0.itemId != row.itemId }
        let all = (others + [row]).sorted(by: WidgetRows.heardLater)
        var seen = Set<WidgetSource>()
        var result: [WidgetSourceRow] = []
        for (index, candidate) in all.enumerated() {
            let newestOfSource = seen.insert(candidate.source).inserted
            if newestOfSource || index < recentKept { result.append(candidate) }
        }
        return result
    }

    /// The rows whose title the app would still show under Continue. A row
    /// goes when its title is finished, when it was hidden from Continue
    /// after it was last heard (`ContinueHidden`), or when the app no longer
    /// owns it: its server or source is removed, or another account signed
    /// in (`owned`).
    static func kept(_ rows: [WidgetSourceRow], finished: Set<String>, hiddenMarkers: [String: Double],
                     owned: (String) -> Bool) -> [WidgetSourceRow] {
        rows.filter { row in
            !finished.contains(row.itemId)
                && !ContinueHidden.isHidden(id: row.itemId, lastUpdate: row.playedAt, markers: hiddenMarkers)
                && owned(row.itemId)
        }
    }
}
