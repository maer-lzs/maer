// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

nonisolated enum GutenbergMusic {
    struct Parts: Equatable, Sendable {
        let composer: String?
        let performer: String?
    }

    static func isMusic(loCC: String?) -> Bool { false }
    static func parts(authors: String?) -> Parts { Parts(composer: nil, performer: nil) }
    static func needsClass(_ stock: CatalogStock) -> Bool { false }
    static func lane(_ stock: CatalogStock, rows: Int, on date: Date) -> [CatalogStockEntry] { [] }

    @MainActor static var known: Set<String> = []
    @MainActor static func note(_ stock: CatalogStock) {}
}
