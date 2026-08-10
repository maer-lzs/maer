// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Befund 10.08.: gehörte Folgen zeigen sich wieder als „in Arbeit" mit einem
/// Rest von exakt drei Minuten — bei sechs Folgen derselben Sendung derselbe
/// Wert. Zwei Ursachen kommen infrage, und sie verlangen entgegengesetzte
/// Reparaturen:
///
///  * **Dauer-These:** „gehört" wird als POSITION = Dauer gespeichert. Wächst
///    die gemeldete Dauer (dynamisch eingesetzte Werbung), fällt die Marke
///    unter die Schwelle, und die Deutung kippt — ohne dass jemand geschrieben
///    hat.
///  * **Sync-These:** Der Server hält eine Position kurz vor Schluss, und der
///    Abgleich holt sie zurück — „gehört" verliert gegen eine Position.
///
/// **Der gespeicherte Eintrag entscheidet es**, denn er ist `[Position,
/// Zeitstempel]`: Ein ALTER Zeitstempel heißt, dass niemand geschrieben hat
/// (dann kippte nur die Deutung); ein FRISCHER heißt, dass etwas
/// darübergeschrieben hat. Deshalb misst dieser Bericht, statt zu raten — und
/// deshalb steht hier kein Fix.
nonisolated enum ProgressDiagnosis {
    struct Entry: Equatable, Sendable {
        let title: String
        let guid: String
        /// Gespeicherte Position in Sekunden.
        let position: Double
        /// Zeitstempel des letzten Schreibens (Sekunden seit 1970).
        let updatedAt: Double
        /// Dauer, die der Feed HEUTE meldet.
        let feedDuration: Double
        /// Dauer, die beim Schreiben galt (dritter Wert, falls vorhanden).
        /// Ihre DIFFERENZ zur heutigen ist der ganze Befund — der Bericht
        /// zeigt deshalb beide.
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
        /// Position ≥ Dauer − 1: die App zeigt „Abgespielt".
        case played
        /// Rest in Sekunden — so viel fehlt nach heutiger Dauer.
        case inProgress(remaining: Double)
        case unplayed
    }

    static func verdict(_ entry: Entry) -> Verdict {
        // Traegt der Eintrag seine damalige Dauer, entscheidet SIE — genau wie
        // im Lesepfad der App (ProgressMark). Ein Messmittel, das anders
        // urteilt als die App, misst sich selbst.
        if let marked = entry.markedDuration, marked > 0 {
            return entry.position >= marked - 1 ? .played
                : (entry.position > 1 ? .inProgress(remaining: max(0, entry.feedDuration - entry.position)) : .unplayed)
        }
        guard entry.feedDuration > 0 else { return .unplayed }
        if entry.position >= entry.feedDuration - 1 { return .played }
        if entry.position > 1 { return .inProgress(remaining: entry.feedDuration - entry.position) }
        return .unplayed
    }

    /// Welche der beiden Thesen der Zeitstempel stützt. Ein Eintrag, der NACH
    /// dem letzten Abgleich geschrieben wurde, kann nicht vom Abgleich
    /// stammen; einer, der genau dabei entstand, sehr wohl.
    enum Trace: Equatable, Sendable {
        /// Vor dem letzten Abgleich geschrieben — niemand hat seither
        /// angefasst, es kippte nur die Deutung.
        case olderThanSync
        /// Zum Zeitpunkt des Abgleichs geschrieben — etwas hat überschrieben.
        case writtenBySync
        /// Nach dem Abgleich geschrieben (z. B. eben markiert).
        case newerThanSync
        case noSyncKnown
    }

    /// Wie nah am Abgleich ein Schreiben liegen darf, um ihm zugerechnet zu
    /// werden. Zwei Minuten: ein Abgleich braucht Sekunden, aber der Bericht
    /// stempelt seinen Abschluss, nicht jeden Einzelschreib.
    static let syncWindow: TimeInterval = 120

    static func trace(_ entry: Entry, lastSync: Double?) -> Trace {
        guard let lastSync, lastSync > 0 else { return .noSyncKnown }
        if entry.updatedAt > lastSync + syncWindow { return .newerThanSync }
        if entry.updatedAt >= lastSync - syncWindow { return .writtenBySync }
        return .olderThanSync
    }

    /// Der Textblock zum Weiterreichen. Absichtlich schlicht und vollständig:
    /// Er soll ohne die App lesbar sein und keine Deutung verstecken.
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
