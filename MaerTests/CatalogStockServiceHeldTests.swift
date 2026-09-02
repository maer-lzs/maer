// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The service holds a decoded stock in memory. The lever that clears
/// derived stores removes the FILES, without passing through the
/// service; after it, `stock()` must answer nil until a new fetch,
/// otherwise the page keeps answering for a stock the person deleted
/// and the lever reports a success it did not deliver.
@MainActor
struct CatalogStockServiceHeldTests {
    private let surface = "heldtest-\(UUID().uuidString)"

    private func entry(_ id: String) -> CatalogStockEntry {
        CatalogStockEntry(id: id, title: id, creator: nil, subjects: ["fiction"],
                          downloads: 1, licenseurl: nil, year: nil)
    }

    @Test("nach dem Leeren antwortet stock() mit nil")
    func clearedStockIsGone() {
        let stock = CatalogStock(surface: surface, takenAt: 1, entries: [entry("a")])
        #expect(CatalogStockStore.shared.save(stock))
        // Rot-Probe: gehalten und gelesen, BEVOR geleert wird.
        #expect(CatalogStockService.shared.stock(surface)?.entries.count == 1)
        #expect(CatalogStockService.shared.index(surface) != nil)
        // The lever's path: files go, the service is not told.
        try? FileManager.default.removeItem(at: CatalogStockStore.fileURL(surface: surface))
        #expect(CatalogStockService.shared.stock(surface) == nil)
        #expect(CatalogStockService.shared.index(surface) == nil)
    }
}
#endif
