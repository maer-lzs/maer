// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The music works of Project Gutenberg: one rule, positive, from the class
/// the Library of Congress gives a work (column `LoCC` of the dump). One
/// class exactly `M` (scores and recordings; `ML`, books about music, is
/// not) makes a work music. Measured on the dump of 27.11.2026: 132 of the
/// 1114 sound works, each with the class `M` alone. They leave the
/// audiobook surfaces and stand in the classical area; the kind of the
/// title (`MediaFamily`) stays a book, so a title already started keeps
/// its place in Continue, its history and its download.
nonisolated enum GutenbergMusic {
    struct Parts: Equatable, Sendable {
        let composer: String?
        let performer: String?
    }

    static func isMusic(loCC: String?) -> Bool {
        guard let loCC else { return false }
        return loCC.split(separator: ";").contains { $0.trimmingCharacters(in: .whitespaces) == "M" }
    }

    /// The composer as the author of the tile and the performers as its
    /// narrators, from the `Authors` cell with its roles in brackets
    /// ("Edison Concert Band; Liszt, Franz, 1811-1886 [Composer]"). Without
    /// a composer the first performer leads.
    static func parts(authors: String?) -> Parts {
        guard let authors else { return Parts(composer: nil, performer: nil) }
        let people: [(name: String, role: String?)] = authors.split(separator: ";").compactMap { raw in
            let text = String(raw)
            let role = text.range(of: #"\[([^\]]+)\]"#, options: .regularExpression)
                .map { String(text[$0].dropFirst().dropLast()) }
            let bare = text.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
            guard let name = FreeCatalog.gutenbergAuthor(bare) else { return nil }
            return (name, role)
        }
        let performing = people.filter { $0.role == nil || $0.role == "Performer" || $0.role == "Conductor" }.map(\.name)
        if let composer = people.first(where: { $0.role == "Composer" })?.name {
            let rest = performing.filter { $0 != composer }
            return Parts(composer: composer, performer: rest.isEmpty ? nil : rest.joined(separator: ", "))
        }
        guard let lead = performing.first ?? people.first?.name else { return Parts(composer: nil, performer: nil) }
        let rest = performing.filter { $0 != lead }
        return Parts(composer: lead, performer: rest.isEmpty ? nil : rest.joined(separator: ", "))
    }

    /// A stock taken before the class was read: due for a full fetch once.
    static func needsClass(_ stock: CatalogStock) -> Bool {
        stock.surface == CatalogSource.gutenberg.rawValue && stock.entries.contains { $0.music == nil }
    }

    /// The music works of the stock as a row: popularity order, the daily
    /// rotation of every row, its own salt.
    static func lane(_ stock: CatalogStock, rows: Int, on date: Date) -> [CatalogStockEntry] {
        let ordered = stock.entries.filter { $0.music == true }
            .sorted { (stock.downloads(of: $0) ?? 0) > (stock.downloads(of: $1) ?? 0) }
        guard !ordered.isEmpty else { return [] }
        let page = CatalogRotation.page(total: ordered.count, rowSize: rows, on: date,
                                        salt: CatalogRotation.salt(forShelf: laneKey))
        let start = min((page - 1) * rows, max(ordered.count - 1, 0))
        return Array(ordered[start...].prefix(rows))
    }

    static let laneKey = "gutenberg-music"

    /// The works the kept stock knows as music, for the surfaces that ask
    /// gutendex, which does not carry the class.
    @MainActor private(set) static var known: Set<String> = []

    @MainActor static func note(_ stock: CatalogStock) {
        guard stock.surface == CatalogSource.gutenberg.rawValue else { return }
        known = Set(stock.entries.filter { $0.music == true }.map(\.id))
    }
}
