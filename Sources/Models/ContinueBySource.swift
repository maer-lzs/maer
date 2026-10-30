// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The app's side of the rows of the large and medium "Continue": which
/// source a title belongs to, and which rows go because the app would no
/// longer show their title. Pure; which rows a new title replaces and what
/// the widget shows of them is `WidgetRows`, shared with the widget.
nonisolated enum ContinueBySource {
    /// The source of a title is its tab, by the app's one assignment
    /// (`MediaFamily.kind(for:markedForm:)`): a catalogue album is music, a
    /// reading an audiobook. Nil for an id no family knows.
    static func source(for id: String, markedForm: ProgressMark.StartedForm? = nil) -> WidgetSource? {
        MediaFamily.kind(for: id, markedForm: markedForm).flatMap { WidgetSource(rawValue: $0.rawValue) }
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
