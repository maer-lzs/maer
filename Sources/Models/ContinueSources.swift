// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// 96cb043 + 2100b09: the ONE collection of what may appear in "Keep
/// listening" — server library, LOCAL files and CATALOG works.
///
/// Third instance of "the row only knows the source it was born from": the
/// row read the server library's `continueListening`, so a locally sideloaded
/// book that is actively playing (the owner's Winterfell) and a started LibriVox
/// work were structurally invisible — for a serverless user the row was empty
/// while he was in the middle of a book.
///
/// Both extra classes keep their position in the SAME place: the
/// `localPosition` second-backup. So this is one collection, not two add-on
/// points — the next class plugs in here instead of being forgotten again.
nonisolated enum ContinueSources {
    /// A started title outside the server library.
    struct Extra: Equatable {
        let id: String
        let position: Double
        let updatedAtMs: Double
        let duration: Double
    }

    /// Which id namespaces carry their progress locally.
    static func isLocallyTracked(_ id: String) -> Bool {
        id.hasPrefix("local:") || FreeCatalog.allPrefixes.contains(where: id.hasPrefix)
    }

    /// Read the started titles from the second-backup store. Pure over the
    /// passed dictionary so the rule is testable without UserDefaults.
    ///
    /// **Dedupe rule (96cb043):** an ABS book that is additionally downloaded
    /// stays ONE entry — the server identity leads, so ids the server library
    /// already knows are skipped here. Local sideloads are their own identity.
    static func started(in defaults: [String: Any],
                        serverKnows: Set<String>,
                        minimumSeconds: Double = 30) -> [Extra] {
        var out: [Extra] = []
        for (key, value) in defaults {
            guard key.hasPrefix("localPosition.") else { continue }
            let id = String(key.dropFirst("localPosition.".count))
            guard isLocallyTracked(id), !serverKnows.contains(id),
                  let stored = value as? [Double], stored.count >= 2 else { continue }
            let position = stored[0]
            // A few seconds are a tap, not a started book.
            guard position >= minimumSeconds else { continue }
            let duration = ProgressMark.markedDuration(stored) ?? 0
            // Finished titles belong to "played", not to "keep listening" —
            // asked through the ONE played rule, never re-implemented here
            // (the project fence caught exactly that in the first draft).
            if duration > 0, ProgressMark.isPlayed(stored: stored, currentDuration: duration) {
                continue
            }
            out.append(Extra(id: id, position: position,
                             updatedAtMs: stored[1], duration: duration))
        }
        return out.sorted { $0.updatedAtMs > $1.updatedAtMs }
    }
}
