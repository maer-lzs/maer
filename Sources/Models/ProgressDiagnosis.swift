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
///    the threshold and the reading flips. Without anyone writing.
///  * **Sync cause:** the server holds a position near the end and the sync
///    brings it back. "played" loses against a position.
///
/// **The stored entry decides it**, because it is `[position, timestamp,
/// duration at the time]`: an OLD timestamp means nobody wrote (only the
/// reading flipped), a FRESH one means something overwrote it. So this
/// measures instead of guessing. And carries no fix.
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
        // If the entry carries its duration, THAT decides. Exactly as the
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
        /// Written before the last sync. Nobody touched it since, only the
        /// reading flipped.
        case olderThanSync
        /// Written at sync time. Something overwrote it.
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
    /// The BOOK view of the same instrument. A book has one
    /// position, not many. But the interesting part is WHERE that position
    /// comes from, so the report puts the sources side by side with their
    /// timestamps. Same model, second view; no second version.
    ///
    /// It is deliberately the measuring tool for the rücksprung candidates
    ///: server vs. local backup vs. cached detail, each with its
    /// own time, plus what the sync queue still owes.
    struct BookSources {
        let serverPosition: Double?
        let serverUpdatedAtMs: Double?
        let localPosition: Double?
        let localSavedAtMs: Double?
        /// The position inside the detail stored at download time. The one
        /// the local start path begins from.
        let cachedPosition: Double?
        let cachedUpdatedAtMs: Double?
        /// What THIS device last pushed successfully. For a downloaded
        /// book it is usually the only local source. The two above are the
        /// deleted backup and the frozen download-time state.
        var flushedPosition: Double? = nil
        var flushedAtMs: Double? = nil
        /// The server's own finished MARKER, next to the numbers. It is carried
        /// separately because the two can disagree. And when a book stands at
        /// exactly its duration while this says no, that disagreement is the
        /// whole finding.
        var serverIsFinished: Bool? = nil
        /// The 0…1 value the app stores and the finished rule reads. Carried
        /// because position-vs-duration and this value can disagree: the
        /// server sends both, and only this one reaches the row.
        var progressFraction: Double? = nil
        /// The last backward jumps, newest last.
        /// `[atMs, start, serverTime, serverAtMs, localTime, localAtMs]`.
        var jumpRing: [[Double]] = []
        let duration: Double
        let isDownloaded: Bool
        let pendingSyncOperations: Int
    }

    static func bookReport(title: String,
                           sources: BookSources,
                           now: Double,
                           format: (Double) -> String,
                           formatTime: (Double) -> String) -> String {
        var lines: [String] = []
        lines.append("Fortschritts-Diagnose (Buch) — \(title)")
        lines.append("erstellt: \(format(now))")
        lines.append("heruntergeladen: \(sources.isDownloaded ? "ja" : "nein")")
        lines.append("offene Sync-Aufträge: \(sources.pendingSyncOperations)")
        lines.append("")
        func line(_ label: String, _ position: Double?, _ atMs: Double?) {
            guard let position else {
                lines.append("\(label): —")
                return
            }
            let stamp = atMs.map { format($0 / 1000) } ?? "ohne Zeitstempel"
            lines.append("\(label): \(formatTime(position)) (\(stamp))")
        }
        line("Server-Stand", sources.serverPosition, sources.serverUpdatedAtMs)
        line("lokaler Sekunden-Backup", sources.localPosition, sources.localSavedAtMs)
        line("gecachter Detail-Stand", sources.cachedPosition, sources.cachedUpdatedAtMs)
        line("zuletzt selbst gesendet", sources.flushedPosition, sources.flushedAtMs)
        lines.append("Dauer: \(sources.duration > 0 ? formatTime(sources.duration) : "unbekannt")")
        // The question this instrument was asked most often and answered least:
        // IS it finished? It showed positions, times and a duration, and the
        // finished state had to be inferred from a missing remaining-time line
        // on the card. Both answers are named, because they can disagree.
        // And when they do, that IS the finding.
        if let server = sources.serverPosition, sources.duration > 0 {
            let byNumbers = SyncRules.isFinished(currentTime: server, duration: sources.duration)
            lines.append("fertig laut Zahlen: \(byNumbers ? "JA" : "nein") "
                         + "(Server-Stand gegen Dauer)")
        }
        if let flag = sources.serverIsFinished {
            lines.append("fertig laut Server-Kennzeichen: \(flag ? "JA" : "nein")")
        }
        // The value the app's OWN rule reads, and its verdict. The two lines
        // above describe the server; this one describes what the row actually
        // decides on. And if the row still shows the book, the answer has to
        // be visible here rather than inferred.
        if let fraction = sources.progressFraction {
            lines.append(String(format: "Fortschrittswert der App: %.6f", fraction))
            lines.append("zaehlt als fertig: "
                         + ((sources.serverIsFinished == true || fraction >= 0.9999) ? "JA" : "NEIN"))
        } else {
            lines.append("Fortschrittswert der App: keiner — dann kann die Reihe ihn nicht als fertig lesen.")
        }
        lines.append("")
        // The verdict the app WOULD reach right now. An instrument that
        // judges differently from the thing it measures is measuring itself.
        if let local = sources.localPosition, let localAt = sources.localSavedAtMs,
           let serverAt = sources.serverUpdatedAtMs, let server = sources.serverPosition {
            // ASK the shared rule, never restate it. My first draft
            // compared inline. Identical today, silently divergent the day
            // someone changes the tolerance or the shape in SyncRules. The
            // whole justification of this instrument is that it judges like
            // the thing it measures.
            if SyncRules.shouldRestoreLocalPosition(savedTime: local, savedAtMs: localAt,
                                                    serverTime: server, serverUpdateMs: serverAt) {
                lines.append("Start würde beim LOKALEN Stand beginnen (er ist neuer).")
            } else {
                lines.append("Start würde beim SERVER-Stand beginnen.")
                if local - server > 60 {
                    lines.append("⚠️ Das wirft \(Int(local - server)) s zurück — genau der gemeldete Rücksprung.")
                }
            }
        } else if let flushed = sources.flushedPosition, let flushedAt = sources.flushedAtMs,
                  SyncRules.shouldPreferFlushedWitness(
                      flushedTime: flushed, flushedAtMs: flushedAt,
                      serverTime: sources.serverPosition ?? 0,
                      serverUpdateMs: sources.serverUpdatedAtMs ?? 0) {
            // The start path asks this rule too. The verdict line
            // used to ask only the crash backup and therefore judged
            // DIFFERENTLY from the thing it measures. That is the same class
            // the inline comparison above was already replaced for.
            lines.append("Start würde bei UNSEREM letzten Push beginnen (Zeuge schlägt den Server).")
        } else {
            lines.append("Nicht beide Seiten bekannt — der Start nimmt, was da ist.")
        }
        // The push witness answers the question the sources alone cannot:
        // did our write reach the server, or is the server's value OUR echo?
        if let flushed = sources.flushedPosition, let flushedAt = sources.flushedAtMs {
            if let server = sources.serverPosition, let serverAt = sources.serverUpdatedAtMs {
                if flushedAt > serverAt {
                    lines.append("Unser letzter Push ist NEUER als der Server-Stand — " +
                                 "er ist dort nicht angekommen (Transport).")
                } else if abs(flushed - server) <= 1 {
                    lines.append("Der Server-Stand IST unser eigener Push (Echo).")
                }
            } else {
                lines.append("Der Server nennt keinen Stand — unser Push ist der einzige Zeuge.")
            }
        }
        if !sources.jumpRing.isEmpty {
            lines.append("")
            lines.append("Rücksprünge (neueste zuletzt):")
            for e in sources.jumpRing where e.count >= 6 {
                lines.append("• \(format(e[0] / 1000)): Start \(formatTime(e[1])) " +
                             "· Server \(formatTime(e[2])) · lokal \(formatTime(e[4]))")
            }
        }
        return lines.joined(separator: "\n")
    }

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
