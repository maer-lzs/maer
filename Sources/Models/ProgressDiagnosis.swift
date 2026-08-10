// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The report that separates the two possible causes when a finished episode
/// shows up as "in progress" again.
///
///  * **Duration cause:** "played" is stored as POSITION = duration. When the
///    reported duration grows (ads inserted per request), the mark falls below
///    the threshold and the reading flips — without anyone writing.
///  * **Sync cause:** the server holds a position near the end and the sync
///    brings it back — "played" loses against a position.
///
/// **The stored entry decides it**, because it is `[position, timestamp,
/// duration at the time]`: an OLD timestamp means nobody wrote (only the
/// reading flipped), a FRESH one means something overwrote it. So this
/// measures instead of guessing — and carries no fix.
nonisolated enum ProgressDiagnosis {
    struct Entry: Equatable, Sendable {
        let title: String
        let guid: String
        /// Stored position in seconds.
        let position: Double
        /// Timestamp of the last write (seconds since 1970).
        let updatedAt: Double
        /// The duration the feed reports TODAY.
        let feedDuration: Double
        /// The duration that applied when it was written (third value, if
        /// present). Its DIFFERENCE to today's is the whole point, so the
        /// report shows both.
        let markedDuration: Double?

        init(title: String, guid: String, position: Double, updatedAt: Double,
             feedDuration: Double, markedDuration: Double? = nil) {
            self.title = title
            self.guid = guid
            self.position = position
            self.updatedAt = updatedAt
            self.feedDuration = feedDuration
            self.markedDuration = markedDuration
        }
    }

    enum Verdict: Equatable, Sendable {
        /// Position >= duration - 1: the app shows it as played.
        case played
        /// Remaining seconds against today's duration.
        case inProgress(remaining: Double)
        case unplayed
    }

    static func verdict(_ entry: Entry) -> Verdict {
        // If the entry carries its duration, THAT decides — exactly as the
        // app's read path does. An instrument that judges differently from the
        // thing it measures is measuring itself.
        if let marked = entry.markedDuration, marked > 0 {
            return entry.position >= marked - 1 ? .played
                : (entry.position > 1 ? .inProgress(remaining: max(0, entry.feedDuration - entry.position)) : .unplayed)
        }
        guard entry.feedDuration > 0 else { return .unplayed }
        if entry.position >= entry.feedDuration - 1 { return .played }
        if entry.position > 1 { return .inProgress(remaining: entry.feedDuration - entry.position) }
        return .unplayed
    }

    /// Which of the two causes the timestamp supports. An entry written AFTER
    /// the last sync cannot come from the sync; one written during it can.
    enum Trace: Equatable, Sendable {
        /// Written before the last sync — nobody touched it since, only the
        /// reading flipped.
        case olderThanSync
        /// Written at sync time — something overwrote it.
        case writtenBySync
        /// Written after the sync (just marked, for instance).
        case newerThanSync
        case noSyncKnown
    }

    /// How close to the sync a write may sit to be attributed to it. Two
    /// minutes: a sync takes seconds, but its report stamps completion rather
    /// than each individual write.
    static let syncWindow: TimeInterval = 120

    static func trace(_ entry: Entry, lastSync: Double?) -> Trace {
        guard let lastSync, lastSync > 0 else { return .noSyncKnown }
        if entry.updatedAt > lastSync + syncWindow { return .newerThanSync }
        if entry.updatedAt >= lastSync - syncWindow { return .writtenBySync }
        return .olderThanSync
    }

    /// The text block to hand on. Deliberately plain and complete: readable
    /// without the app, hiding no interpretation.
    static func report(show: String,
                       entries: [Entry],
                       lastSync: Double?,
                       now: Double,
                       format: (Double) -> String) -> String {
        var lines: [String] = []
        lines.append("Fortschritts-Diagnose — \(show)")
        lines.append("erstellt: \(format(now))")
        lines.append("letzter gpodder-Abgleich: \(lastSync.map(format) ?? "unbekannt")")
        lines.append("")
        if entries.isEmpty {
            lines.append("Keine gespeicherten Positionen in dieser Sendung.")
            return lines.joined(separator: "\n")
        }
        for entry in entries {
            lines.append("• \(entry.title)")
            lines.append("  guid: \(entry.guid)")
            lines.append("  Position: \(Int(entry.position)) s · Feed-Dauer heute: \(Int(entry.feedDuration)) s")
            if let marked = entry.markedDuration, marked > 0 {
                let diff = Int(entry.feedDuration - marked)
                lines.append("  Dauer beim Schreiben: \(Int(marked)) s · Differenz zu heute: \(diff) s")
            } else {
                lines.append("  Dauer beim Schreiben: nicht gespeichert (alter Eintrag)")
            }
            switch verdict(entry) {
            case .played:
                lines.append("  Zustand: gilt als gehört")
            case .inProgress(let remaining):
                lines.append("  Zustand: erscheint als in Arbeit, Rest \(Int(remaining)) s"
                             + " — die Position entspricht einer Dauer von \(Int(entry.position)) s")
            case .unplayed:
                lines.append("  Zustand: ungehört")
            }
            lines.append("  geschrieben: \(format(entry.updatedAt))")
            switch trace(entry, lastSync: lastSync) {
            case .olderThanSync:
                lines.append("  ⇒ ALT (vor dem letzten Abgleich): niemand hat geschrieben — Dauer-These")
            case .writtenBySync:
                lines.append("  ⇒ FRISCH (zum Abgleich): etwas hat überschrieben — Sync-These")
            case .newerThanSync:
                lines.append("  ⇒ nach dem Abgleich geschrieben (z. B. gerade markiert)")
            case .noSyncKnown:
                lines.append("  ⇒ kein Abgleich bekannt — der Zeitstempel allein entscheidet nichts")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
