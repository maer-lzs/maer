// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

@MainActor
enum CatalogRowKeep {
    static func enabled(_ gates: CatalogGates) -> Set<FreeCatalogLoader.Rows.Row> { [] }
    static func merge(previous: FreeCatalogLoader.Rows, loaded: FreeCatalogLoader.Rows,
                      enabled: Set<FreeCatalogLoader.Rows.Row>) -> FreeCatalogLoader.Rows { loaded }
    static func written(_ rows: FreeCatalogLoader.Rows) -> [CatalogRowStore.Key: [LibraryItem]] { [:] }
    static func written(_ rows: CatalogSourceLoader.SourceRows) -> [CatalogRowStore.Key: [LibraryItem]] { [:] }
    static func restore(_ stored: [CatalogRowStore.Key: [LibraryItem]], into rows: inout FreeCatalogLoader.Rows) {}
    static func restore(_ stored: [CatalogRowStore.Key: [LibraryItem]], into rows: inout CatalogSourceLoader.SourceRows) {}
}
