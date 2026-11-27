// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

actor CatalogRowStore {
    static let family = "catalog"
    static let schemaVersion = 1

    enum Key: String, CaseIterable, Sendable {
        case booksDiscover = "books.discover", booksTab = "books.tab"
        case classical, netlabels, musopen
        case librivoxNew = "librivox.new", librivoxPopular = "librivox.popular"
        case archiveBooks = "archive.books", gutenberg, oldTimeRadio = "old.time.radio"
    }

    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) async throws {
        self.connection = connection
    }

    static var directory: URL? { nil }

    static func open() async throws -> CatalogRowStore {
        try await CatalogRowStore(connection: SQLiteConnection(path: ":memory:"))
    }

    func replace(_ key: Key, items: [LibraryItem], atMs: Double) async throws {}
    func noteFailure(_ key: Key, reason: String, atMs: Double) async throws {}
    func rows() async throws -> [Key: [LibraryItem]] { [:] }
    func failures() async throws -> [Key: String] { [:] }
}
