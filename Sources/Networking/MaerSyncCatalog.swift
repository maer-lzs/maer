// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

nonisolated struct MaerSyncCatalogQuery: Equatable, Sendable {
    var source: String
    var after: String?
    var count: Int
    var since: Int?
    var ifNoneMatch: String?
}

nonisolated struct MaerSyncCatalogRow: Equatable, Sendable {
    let id: String
    let deleted: Bool
    let json: Data
}

nonisolated struct MaerSyncCatalogPage: Equatable, Sendable {
    let format: Int
    let source: String
    let version: Int
    let rows: [MaerSyncCatalogRow]
    let next: String?
    let etag: String?
}

nonisolated enum MaerSyncCatalogAnswer: Equatable, Sendable {
    case page(MaerSyncCatalogPage)
    case unchanged
    case absent
    case gone
    case refused(Int)
    case busy(retryAfter: Int?)
}

protocol MaerSyncCatalogReading: Sendable {
    func catalog(_ query: MaerSyncCatalogQuery, access: MaerSyncAccess) async throws -> MaerSyncCatalogAnswer
}

nonisolated enum CatalogIndexSource: String, CaseIterable, Sendable {
    case librivox, archiveBuch = "archive-buch", netlabel, schellack, otr, gutenberg, musopen
}

nonisolated enum CatalogIndexRun {
    typealias Ask = @Sendable (MaerSyncCatalogQuery) async throws -> MaerSyncCatalogAnswer

    enum Outcome: Equatable, Sendable {
        case taken(version: Int), unchanged, noCatalog, later(retryAfter: Int?), nothingTaken(String)
    }

    static let pageSize = 5000
    static let format = 1

    static func run(_ source: CatalogIndexSource, store: CatalogRowStore, ask: Ask,
                    pageSize: Int = pageSize, nowMs: Double) async -> Outcome { .nothingTaken("not built") }

    static func isDue(_ state: CatalogRowStore.IndexState?, nowMs: Double) -> Bool { true }

    @MainActor static func sources(_ gates: CatalogGates) -> [CatalogIndexSource] { [] }
}
