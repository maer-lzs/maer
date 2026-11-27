// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What of a fetched catalogue row stands and what goes into the database:
/// a row that failed or was cancelled keeps the last state, a switched-off
/// row shows nothing, and only a row that came whole is written. Jamendo is
/// never written: its terms forbid keeping its answers.
@MainActor
enum CatalogRowKeep {
    typealias Row = FreeCatalogLoader.Rows.Row

    /// The rows of the start page whose source is on, as the loader asks.
    static func enabled(_ gates: CatalogGates) -> Set<Row> {
        var on: Set<Row> = []
        if gates.librivox && gates.freeAudiobooksArea { on.insert(.books) }
        if gates.freeClassical && gates.archiveBooks { on.insert(.classical) }
        if gates.netlabels && gates.archiveBooks { on.insert(.netlabels) }
        if gates.musopen { on.insert(.musopen) }
        if gates.jamendo { on.insert(.freeMusic) }
        return on
    }

    /// The fetched rows over the shown ones. A row that came empty (a
    /// failure with its line, or a cancel) keeps what was shown; a row that
    /// is off is empty. Jamendo stays as fetched: its day store keeps it.
    static func merge(previous: FreeCatalogLoader.Rows, loaded: FreeCatalogLoader.Rows,
                      enabled: Set<Row>) -> FreeCatalogLoader.Rows {
        var merged = loaded
        func keep(_ row: Row, _ field: WritableKeyPath<FreeCatalogLoader.Rows, [LibraryItem]>) {
            if !enabled.contains(row) {
                merged[keyPath: field] = []
            } else if loaded[keyPath: field].isEmpty {
                merged[keyPath: field] = previous[keyPath: field]
            }
        }
        keep(.books, \.discoverBooks)
        keep(.books, \.tabBooks)
        keep(.classical, \.classical)
        keep(.netlabels, \.netlabels)
        keep(.musopen, \.musopen)
        return merged
    }

    /// The rows of the start page that came whole and go into the database.
    static func written(_ rows: FreeCatalogLoader.Rows) -> [CatalogRowStore.Key: [LibraryItem]] {
        let all: [CatalogRowStore.Key: [LibraryItem]] = [
            .booksDiscover: rows.discoverBooks, .booksTab: rows.tabBooks,
            .classical: rows.classical, .netlabels: rows.netlabels, .musopen: rows.musopen]
        return all.filter { !$0.value.isEmpty }
    }

    /// The source rows that came whole and go into the database.
    static func written(_ rows: CatalogSourceLoader.SourceRows) -> [CatalogRowStore.Key: [LibraryItem]] {
        let all: [CatalogRowStore.Key: [LibraryItem]] = [
            .librivoxNew: rows.librivoxNew, .librivoxPopular: rows.librivoxPopular,
            .archiveBooks: rows.archiveBooks, .gutenberg: rows.gutenberg, .oldTimeRadio: rows.oldTimeRadio]
        return all.filter { !$0.value.isEmpty }
    }

    /// The failed rows of a fetch of the start page, by their key.
    static func failed(_ rows: FreeCatalogLoader.Rows) -> [CatalogRowStore.Key: String] {
        var failed: [CatalogRowStore.Key: String] = [:]
        if let reason = rows.problems[.books] { failed[.booksDiscover] = reason; failed[.booksTab] = reason }
        if let reason = rows.problems[.classical] { failed[.classical] = reason }
        if let reason = rows.problems[.netlabels] { failed[.netlabels] = reason }
        if let reason = rows.problems[.musopen] { failed[.musopen] = reason }
        return failed
    }

    /// The failed source rows, by their key.
    static func failed(_ rows: CatalogSourceLoader.SourceRows) -> [CatalogRowStore.Key: String] {
        var failed: [CatalogRowStore.Key: String] = [:]
        for (source, reason) in rows.failures {
            switch source {
            case .librivox: failed[.librivoxNew] = reason; failed[.librivoxPopular] = reason
            case .archiveBooks: failed[.archiveBooks] = reason
            case .gutenberg: failed[.gutenberg] = reason
            case .oldTimeRadio: failed[.oldTimeRadio] = reason
            case .oerr, .independents: break
            }
        }
        return failed
    }

    /// The kept rows into the rows of the start page, only where a row is
    /// still empty and its source is on.
    static func restore(_ stored: [CatalogRowStore.Key: [LibraryItem]], into rows: inout FreeCatalogLoader.Rows,
                        enabled: Set<Row>) {
        func fill(_ row: Row, _ key: CatalogRowStore.Key, _ field: WritableKeyPath<FreeCatalogLoader.Rows, [LibraryItem]>) {
            guard enabled.contains(row), rows[keyPath: field].isEmpty, let kept = stored[key] else { return }
            rows[keyPath: field] = kept
        }
        fill(.books, .booksDiscover, \.discoverBooks)
        fill(.books, .booksTab, \.tabBooks)
        fill(.classical, .classical, \.classical)
        fill(.netlabels, .netlabels, \.netlabels)
        fill(.musopen, .musopen, \.musopen)
    }

    /// The kept source rows, only where a row is still empty and its source
    /// is on.
    static func restore(_ stored: [CatalogRowStore.Key: [LibraryItem]], into rows: inout CatalogSourceLoader.SourceRows,
                        allowed: (CatalogSource) -> Bool) {
        func fill(_ source: CatalogSource, _ key: CatalogRowStore.Key,
                  _ field: WritableKeyPath<CatalogSourceLoader.SourceRows, [LibraryItem]>) {
            guard allowed(source), rows[keyPath: field].isEmpty, let kept = stored[key] else { return }
            rows[keyPath: field] = kept
        }
        fill(.librivox, .librivoxNew, \.librivoxNew)
        fill(.librivox, .librivoxPopular, \.librivoxPopular)
        fill(.archiveBooks, .archiveBooks, \.archiveBooks)
        fill(.gutenberg, .gutenberg, \.gutenberg)
        fill(.oldTimeRadio, .oldTimeRadio, \.oldTimeRadio)
    }
}
