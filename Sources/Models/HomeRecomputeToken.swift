// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// When Home recomputes its rows: on a change of CONTENT, never of a count.
/// It used to count three lists (the library, the recently added, the
/// queue), so a list that changed at equal length changed nothing, against
/// the house rule. Pure, so the rule has a witness.
nonisolated enum HomeRecomputeToken {
    static func make(isActive: Bool,
                     entryIds: [String],
                     continueEntries: [(id: String, lastUpdate: Double)],
                     recentlyAddedIds: [String],
                     queueIds: [String],
                     recommendationsEnabled: Bool,
                     hiddenRevision: Int,
                     showFeeds: [String],
                     revision: Int) -> String {
        let entries = ContentToken.of(entryIds)
        // A Continue entry that moves (a start, a takeover, a position from
        // the other device) changes the token at equal count.
        let continuing = ContentToken.of(continueEntries.map { "\($0.id)|\($0.lastUpdate)" })
        let added = ContentToken.of(recentlyAddedIds)
        // Up Next shows the queue IN ORDER, so the position is part of its
        // content; the token alone would not see a reordering.
        let queue = ContentToken.of(queueIds.enumerated().map { "\($0.offset)|\($0.element)" })
        let shows = ContentToken.of(showFeeds)
        return "\(isActive)-\(entries)-\(continuing)-\(added)-\(queue)-\(recommendationsEnabled)-\(hiddenRevision)-\(shows)-\(revision)"
    }
}
