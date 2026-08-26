// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The ONE mechanism behind "resolve a missing piece of
/// metadata lazily and remember it". Feed artwork, LibriVox
/// runtimes, and whatever comes next. Session cache plus a persisted one,
/// TTL per outcome, and the rule that cost us every radio logo once
/// built in rather than re-decided per service:
///
/// **A failed lookup is not a finding.** Only a clean run may be written
/// down. Negative or positive. Callers pass their outcome explicitly, so
/// "no answer" can never masquerade as "nothing there".
nonisolated struct ResolutionCacheStore<Value: Codable & Sendable>: Sendable {
    /// What a lookup produced. `failed` is deliberately NOT storable.
    enum Outcome {
        case found(Value)
        /// Ran cleanly, the source has nothing.
        case absent
        case failed
    }

    struct Stored: Codable {
        var value: Value?
        var resolvedAt: Double
        /// Der FINGERABDRUCK der Regel, aus der dieser Wert stammt.
        ///
        /// Ein zwischengespeichertes Ergebnis gilt nur, solange die Regel
        /// gilt, die es erzeugt hat. Der Tages-Speicher der Gutenberg-Faecher
        /// war allein nach dem Fach-Namen abgelegt. Wurden die Begriffe
        /// ausgetauscht, lieferte er bis zu vierundzwanzig Stunden weiter die
        /// Antwort der ALTEN Regel, und nach einem Update saehe jeder Nutzer
        /// einen Tag lang die alten Faecher.
        ///
        /// Mit dem Abdruck im Eintrag ist ein Wert der alten Regel nach einer
        /// Aenderung schlicht nicht mehr auffindbar. Automatisch, ohne dass
        /// jemand an ein Leeren denken muss. Ein Generations-Zaehler waere die
        /// schwaechere Form: er verlaesst sich darauf, dass niemand ihn
        /// vergisst.
        var rule: String?
    }

    let key: String
    let positiveTTL: TimeInterval
    let negativeTTL: TimeInterval

    init(key: String, positiveTTL: TimeInterval = 30 * 24 * 3600,
         negativeTTL: TimeInterval = 7 * 24 * 3600) {
        self.key = key
        self.positiveTTL = positiveTTL
        self.negativeTTL = negativeTTL
    }

    /// Entries still within their TTL, ready for the session cache.
    /// Entries still within their TTL, ready for the session cache.
    ///
    /// `rule` liefert je Eintrag den Abdruck der Regel, die HEUTE gilt.
    /// Ein Eintrag, dessen Abdruck nicht passt, wird ueberlesen. Er ist die
    /// Antwort einer Regel, die es nicht mehr gibt. Wer keine Regel hat
    /// (`nil`), bekommt das alte Verhalten.
    func load(defaults: UserDefaults = .standard, now: Date = Date(),
              rule: ((String) -> String)? = nil) -> [String: Value?] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else { return [:] }
        let nowSeconds = now.timeIntervalSince1970
        var out: [String: Value?] = [:]
        for (id, entry) in stored {
            let ttl = entry.value == nil ? negativeTTL : positiveTTL
            guard nowSeconds - entry.resolvedAt <= ttl else { continue }
            if let rule, entry.rule != rule(id) { continue }
            out[id] = entry.value
        }
        return out
    }

    /// Writes an outcome. Returns whether anything was stored. `failed`
    /// never is, which is the whole point of this type.
    @discardableResult
    func store(_ outcome: Outcome, for id: String, rule: String? = nil,
               defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        let value: Value?
        switch outcome {
        case .found(let found): value = found
        case .absent: value = nil
        case .failed: return false
        }
        var stored = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        stored[id] = Stored(value: value, resolvedAt: now.timeIntervalSince1970, rule: rule)
        guard let data = try? JSONEncoder().encode(stored) else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}
