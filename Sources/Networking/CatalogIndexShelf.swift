// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The rows of the free catalogues from the index of a Mär Sync service.
/// Every archive.org row and shelf asks one question in the popularity
/// order; when the index carries the source of that question, the page comes
/// from the index instead: ordered by the popularity step of the source, cut
/// at the page the caller reckoned with its rotation. Without the source in
/// the index the question goes to archive.org as before.
nonisolated enum CatalogIndexShelf {
    /// What a row of the index carries for a tile. A field the app does not
    /// know is passed over.
    struct Entry: Equatable, Sendable {
        let id: String
        let title: String?
        let creator: String?
        let year: Int?
        let licence: String?
        let language: String?
        let shelves: [String]
        /// `laden`: false bars the item from the library; nil when missing.
        var load: Bool? = nil
        /// The tenth of its source the row stands in, 1 the most popular;
        /// nil when the source states no number or the row came through a
        /// delta first.
        let step: Int?
    }

    /// The source of the index a question of a row names, the shelf within
    /// it, and the language variants the question filters on.
    struct Target: Equatable, Sendable {
        let source: String
        let shelf: String?
        let languages: [String]
    }

    /// One row of the index, or nil when it is none; a row passed over
    /// writes its source and its reason to the log.
    static func entry(_ json: Data, source: String = "-") -> Entry? {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: json)
        } catch {
            Logger.library.error("CATALOG index \(source, privacy: .public) row passed over reason=\(String(describing: error), privacy: .public)")
            return nil
        }
        guard let object = parsed as? [String: Any] else {
            Logger.library.error("CATALOG index \(source, privacy: .public) row passed over reason=not an object")
            return nil
        }
        guard let id = object["id"] as? String, !id.isEmpty else {
            Logger.library.error("CATALOG index \(source, privacy: .public) row passed over reason=no id")
            return nil
        }
        let rights = object["rechte"] as? [String: Any]
        let step = (object["beliebt_stufe"] as? Int).flatMap { (1...10).contains($0) ? $0 : nil }
        return Entry(id: id, title: object["titel"] as? String, creator: object["urheber"] as? String,
                     year: object["jahr"] as? Int, licence: rights?["url"] as? String,
                     language: object["sprache"] as? String, shelves: object["reihen"] as? [String] ?? [],
                     load: object["laden"] as? Bool, step: step)
    }

    /// The lower step first, a row without a step behind every row with one;
    /// within a step the order of the id, which is the order of the service.
    static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            switch (a.step, b.step) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
            }
        }
    }

    /// The collection a source's items carry on archive.org. Their form
    /// (a work in parts or an album of tracks) hangs on it.
    static func collection(of source: String) -> String? {
        switch source {
        case "librivox": "librivoxaudio"
        case "archive-buch": "audio_bookspoetry"
        case "otr": "oldtimeradio"
        case "netlabel": "netlabels"
        case "schellack": "georgeblood"
        default: nil
        }
    }

    /// Which source of the index a question of a row is. Only the
    /// questions of the rows and shelves; a genre, a search or anything else
    /// names none and stays with archive.org.
    static func target(query: String) -> Target? {
        let librivox = "collection:librivoxaudio AND "
        if query == ArchiveOrgClient.archiveBaseQuery(for: .librivox) {
            return Target(source: "librivox", shelf: nil, languages: [])
        }
        if query.hasPrefix(librivox), let languages = languages(in: String(query.dropFirst(librivox.count))) {
            return Target(source: "librivox", shelf: nil, languages: languages)
        }
        if let books = ArchiveOrgClient.archiveBaseQuery(for: .archiveBooks) {
            if query == books { return Target(source: "archive-buch", shelf: nil, languages: []) }
            if query.hasPrefix(books + " AND "),
               let languages = languages(in: String(query.dropFirst(books.count + 5))) {
                return Target(source: "archive-buch", shelf: nil, languages: languages)
            }
        }
        if query == ArchiveOrgClient.oldTimeRadioQuery || query == ArchiveOrgClient.archiveBaseQuery(for: .oldTimeRadio) {
            return Target(source: "otr", shelf: nil, languages: [])
        }
        if query == ArchiveMusicCatalog.netlabels.query { return Target(source: "netlabel", shelf: nil, languages: []) }
        if query == ArchiveMusicCatalog.shellacAll.query { return Target(source: "schellack", shelf: nil, languages: []) }
        if let shelf = ArchiveMusicCatalog.shellacShelves.first(where: { $0.query == query }) {
            return Target(source: "schellack", shelf: shelf.key, languages: [])
        }
        return nil
    }

    /// The variants of a language clause (`(language:"deu" OR …)`), nil when
    /// the text is anything else.
    private static func languages(in clause: String) -> [String]? {
        guard clause.hasPrefix("(language:\""), clause.hasSuffix("\")") else { return nil }
        let parts = clause.dropFirst().dropLast().components(separatedBy: " OR ")
        var variants: [String] = []
        for part in parts {
            guard part.hasPrefix("language:\""), part.hasSuffix("\"") else { return nil }
            variants.append(String(part.dropFirst(10).dropLast()))
        }
        return variants.isEmpty ? nil : variants
    }

    /// One page of the ordered rows that match the target, and their count.
    static func answer(_ ordered: [Entry], target: Target, rows: Int, page: Int) -> (docs: [ArchivePopularDoc], total: Int) {
        let matching = ordered.filter { entry in
            (target.shelf.map { entry.shelves.contains($0) } ?? true)
                && (target.languages.isEmpty || entry.language.map { target.languages.contains($0) } == true)
        }
        let start = max(page - 1, 0) * max(rows, 0)
        guard start < matching.count else { return ([], matching.count) }
        let slice = matching[start...].prefix(rows)
        return (slice.map { doc($0, source: target.source) }, matching.count)
    }

    /// A row as the entry archive.org would give: the id without its prefix,
    /// the licence the source states, the collection of the source.
    static func doc(_ entry: Entry, source: String) -> ArchivePopularDoc {
        let identifier = FreeCatalog.archiveIdentifier(of: entry.id) ?? entry.id
        return ArchivePopularDoc(identifier: identifier,
                                 title: entry.title.map { ArchiveStringList([$0]) },
                                 creator: entry.creator.map { ArchiveStringList([$0]) },
                                 downloads: nil, runtime: nil, licenseurl: entry.licence,
                                 year: entry.year.map { ArchiveStringList([String($0)]) },
                                 subject: nil,
                                 collection: collection(of: source).map { ArchiveStringList([$0]) },
                                 mayLoad: entry.load)
    }
}

/// Reads the index of a source once per version and answers the questions
/// of the rows from it.
actor CatalogIndexShelfReader {
    typealias Read = @Sendable (_ source: String) async -> (version: Int, rows: [Data])?
    typealias Version = @Sendable (_ source: String) async -> Int?

    private let read: Read
    private let version: Version?
    private var kept: [String: (version: Int, ordered: [CatalogIndexShelf.Entry])] = [:]
    /// How often a source's rows were parsed and ordered.
    private(set) var parsed = 0

    init(read: @escaping Read, version: Version? = nil) {
        self.read = read
        self.version = version
    }

    static let shared = CatalogIndexShelfReader(
        read: { source in
            do {
                let store = try await CatalogRowStore.open()
                guard let state = try await store.indexState(source) else { return nil }
                return (state.version, Array(try await store.indexRows(source).values))
            } catch {
                Logger.library.error("CATALOG index \(source, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
                return nil
            }
        },
        version: { source in
            do {
                return try await CatalogRowStore.open().indexState(source)?.version
            } catch {
                Logger.library.error("CATALOG index \(source, privacy: .public) state unreadable: \(String(describing: error), privacy: .public)")
                return nil
            }
        })

    /// The page from the index, nil when the question is no row's, the
    /// index does not carry its source (no run yet, no rows) or the page
    /// would be empty.
    func answer(query: String, rows: Int, page: Int) async -> (docs: [ArchivePopularDoc], total: Int)? {
        guard let target = CatalogIndexShelf.target(query: query),
              let ordered = await ordered(target.source) else { return nil }
        let answer = CatalogIndexShelf.answer(ordered, target: target, rows: rows, page: page)
        // An empty page is no answer of the index: a source it holds fewer
        // rows of than the rotation reckons, or a shelf it holds none of,
        // goes to archive.org instead of standing empty.
        guard !answer.docs.isEmpty else {
            Logger.library.notice("CATALOG index \(target.source, privacy: .public) shelf=\(target.shelf ?? "-", privacy: .public) page=\(page) empty of=\(answer.total), asking the source")
            return nil
        }
        Logger.library.notice("CATALOG index \(target.source, privacy: .public) shelf=\(target.shelf ?? "-", privacy: .public) page=\(page) docs=\(answer.docs.count) of=\(answer.total)")
        return answer
    }

    private func ordered(_ source: String) async -> [CatalogIndexShelf.Entry]? {
        if let version, let held = kept[source], await version(source) == held.version {
            return held.ordered.isEmpty ? nil : held.ordered
        }
        guard let fresh = await read(source), fresh.version > 0 else { return nil }
        if let held = kept[source], held.version == fresh.version {
            return held.ordered.isEmpty ? nil : held.ordered
        }
        let ordered = CatalogIndexShelf.ordered(fresh.rows.compactMap { CatalogIndexShelf.entry($0, source: source) })
        parsed += 1
        kept[source] = (fresh.version, ordered)
        return ordered.isEmpty ? nil : ordered
    }
}
