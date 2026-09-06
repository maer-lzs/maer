// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Does an author field name this author? The library groups books by the
/// whole field, so a search hit compared with `==` missed the two shapes a
/// field really has: "Nachname, Vorname" for the same person, and several
/// people in one field.
nonisolated enum AuthorMatch {
    /// Separators that certainly separate PEOPLE. A comma is deliberately
    /// not among them: it is the separator of "Nachname, Vorname" just as
    /// often, and without measured data the two cannot be told apart. The
    /// comma shape is covered by the swap below instead.
    private static let separators = [";", " & ", " und ", " and ", " / ", " · "]

    /// Case and diacritics folded, punctuation dropped, spaces collapsed.
    static func normalized(_ raw: String) -> String {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let cleaned = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// "Tolkien, J. R. R." and "J. R. R. Tolkien" are the same person: the
    /// normalised form and the form with the two halves swapped.
    static func forms(of raw: String) -> Set<String> {
        var out: Set<String> = []
        let name = normalized(raw)
        guard !name.isEmpty else { return out }
        out.insert(name)
        let halves = raw.components(separatedBy: ",")
        if halves.count == 2 {
            let swapped = normalized(halves[1] + " " + halves[0])
            if !swapped.isEmpty { out.insert(swapped) }
        }
        return out
    }

    /// The people a field names: the whole field, and its parts where a
    /// certain separator says there are several.
    static func people(in field: String) -> [String] {
        var parts = [field]
        for separator in separators where field.contains(separator) {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Does this field name that author?
    static func field(_ field: String?, names author: String) -> Bool {
        guard let field, !field.isEmpty else { return false }
        let wanted = forms(of: author)
        guard !wanted.isEmpty else { return false }
        for person in people(in: field) where !forms(of: person).isDisjoint(with: wanted) { return true }
        return false
    }
}
