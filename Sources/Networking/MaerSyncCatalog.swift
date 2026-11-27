// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// One request of the catalogue of a Mär Sync service (addition katalog-1
/// to contract version 6): a source, a page (`after`, `count`), a delta
/// (`since`) and the tag of the same address.
nonisolated struct MaerSyncCatalogQuery: Equatable, Sendable {
    var source: String
    var after: String?
    var count: Int
    var since: Int?
    var ifNoneMatch: String?
}

/// A row as it came: its id, whether it is a deletion mark, and the row
/// itself as JSON, kept as the service wrote it.
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

    /// Reads a page; a page without its fields is unreadable, a row without
    /// an id is left out.
    static func read(_ body: Data, etag: String?) throws -> MaerSyncCatalogPage {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let format = object["katalog_format"] as? Int, let source = object["quelle"] as? String,
              let version = object["version"] as? Int, let rows = object["zeilen"] as? [[String: Any]]
        else { throw MaerSyncFailure.unreadable }
        let read = try rows.compactMap { row -> MaerSyncCatalogRow? in
            guard let id = row["id"] as? String else { return nil }
            return MaerSyncCatalogRow(id: id, deleted: row["geloescht"] as? Bool ?? false,
                                      json: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
        }
        return MaerSyncCatalogPage(format: format, source: source, version: version, rows: read,
                                   next: object["weiter"] as? String, etag: etag)
    }
}

nonisolated enum MaerSyncCatalogAnswer: Equatable, Sendable {
    case page(MaerSyncCatalogPage)
    case unchanged
    case absent
    case gone
    case refused(Int)
    case busy(retryAfter: Int?)
}

/// The door reads the catalogue; its own protocol, so the many witnesses of
/// the transport need nothing new.
protocol MaerSyncCatalogReading: Sendable {
    func catalog(_ query: MaerSyncCatalogQuery, access: MaerSyncAccess) async throws -> MaerSyncCatalogAnswer
}

/// The sources of the index this app reads: the free catalogues of its
/// rows. Radio and the feeds of the broadcasters come later, with the rows
/// that read them.
nonisolated enum CatalogIndexSource: String, CaseIterable, Sendable {
    case librivox, archiveBuch = "archive-buch", netlabel, schellack, otr, gutenberg, musopen
}

/// One run of the index of one source: the delta from the kept version, or
/// the full state page by page. Only a whole walk is taken over, in one
/// transaction; anything else keeps the state (unknown never becomes empty).
nonisolated enum CatalogIndexRun {
    typealias Ask = @Sendable (MaerSyncCatalogQuery) async throws -> MaerSyncCatalogAnswer

    enum Outcome: Equatable, Sendable {
        case taken(version: Int), unchanged, noCatalog, later(retryAfter: Int?), nothingTaken(String)
    }

    static let pageSize = 5000
    static let format = 1
    /// A day between two runs of a source.
    static let dayMs: Double = 24 * 3_600_000
    /// How often a walk starts again when the version moves under it.
    static let walksAtMost = 3

    private enum Walk {
        case whole(version: Int, rows: [MaerSyncCatalogRow], etag: String?, address: String)
        case answer(MaerSyncCatalogAnswer)
        case moved
    }

    /// The address a tag belongs to: source, delta and page.
    static func address(_ query: MaerSyncCatalogQuery) -> String {
        "\(query.source)|\(query.since.map(String.init) ?? "-")|\(query.after ?? "-")|\(query.count)"
    }

    static func run(_ source: CatalogIndexSource, store: CatalogRowStore, ask: Ask,
                    pageSize: Int = pageSize, nowMs: Double) async -> Outcome {
        let name = source.rawValue
        let outcome: Outcome
        do {
            let known = try await store.indexState(name)
            outcome = try await walk(source, known: known, store: store, ask: ask, pageSize: pageSize, nowMs: nowMs)
        } catch {
            outcome = .nothingTaken(FailureReason.of(error))
        }
        let notBefore: Double?
        if case .later(let seconds) = outcome { notBefore = nowMs + Double(seconds ?? 3_600) * 1000 } else { notBefore = nil }
        do { try await store.noteIndexRead(name, atMs: nowMs, notBeforeMs: notBefore) } catch {
            Logger.library.error("CATALOG index \(name, privacy: .public) read not noted: \(FailureReason.of(error), privacy: .public)")
        }
        Logger.library.notice("CATALOG index \(name, privacy: .public) \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private static func walk(_ source: CatalogIndexSource, known: CatalogRowStore.IndexState?, store: CatalogRowStore,
                             ask: Ask, pageSize: Int, nowMs: Double) async throws -> Outcome {
        let name = source.rawValue
        if let known, known.version > 0 {
            switch try await pages(name, since: known.version, tag: known, ask: ask, pageSize: pageSize) {
            case .whole(let version, let rows, let etag, let address):
                // The same version without rows is the service saying
                // nothing changed; an older one is never taken.
                if version == known.version, rows.isEmpty {
                    // Only the tag of this address is kept, for the next 304.
                    try await store.takeDelta(name, rows: [], version: version, etag: etag, etagAddress: address, atMs: nowMs)
                    return .unchanged
                }
                guard version > known.version else {
                    Logger.library.notice("CATALOG index \(name, privacy: .public) delta of version \(version) not above \(known.version), not taken")
                    return .nothingTaken("version \(version) not above \(known.version)")
                }
                try await store.takeDelta(name, rows: rows, version: version, etag: etag, etagAddress: address, atMs: nowMs)
                return .taken(version: version)
            case .answer(.gone), .answer(.refused(400)):
                // 410: older than the service answers; 400: above its
                // version, a service that was reset. Both read the full state.
                Logger.library.notice("CATALOG index \(name, privacy: .public) delta refused, the full state is read")
            case .answer(let other):
                return outcome(of: other)
            case .moved:
                return .nothingTaken("the version moved in every walk")
            }
        }
        switch try await pages(name, since: nil, tag: known, ask: ask, pageSize: pageSize) {
        case .whole(let version, let rows, let etag, let address):
            // Version 0 is "no run yet", not an empty source.
            guard version > 0 else { return .nothingTaken("version 0") }
            try await store.takeFull(name, rows: rows, version: version, etag: etag, etagAddress: address, atMs: nowMs)
            return .taken(version: version)
        case .answer(let other):
            return outcome(of: other)
        case .moved:
            return .nothingTaken("the version moved in every walk")
        }
    }

    private static func outcome(of answer: MaerSyncCatalogAnswer) -> Outcome {
        switch answer {
        case .unchanged: return .unchanged
        case .absent: return .noCatalog
        case .busy(let seconds): return .later(retryAfter: seconds)
        case .gone: return .nothingTaken("410 on the full state")
        case .refused(let status): return .nothingTaken("status \(status)")
        case .page: return .nothingTaken("a page where none was due")
        }
    }

    /// Walks every page of one address; starts again when the version
    /// moves between two pages. The tag goes only with the address it came
    /// with, on the first page.
    private static func pages(_ name: String, since: Int?, tag: CatalogRowStore.IndexState?,
                              ask: Ask, pageSize: Int) async throws -> Walk {
        for _ in 0..<walksAtMost {
            var rows: [MaerSyncCatalogRow] = []
            var version: Int?
            var after: String?
            var firstAddress = ""
            var firstTag: String?
            var moved = false
            repeat {
                var query = MaerSyncCatalogQuery(source: name, after: after, count: pageSize, since: since, ifNoneMatch: nil)
                if after == nil {
                    firstAddress = address(query)
                    if let tag, tag.etagAddress == firstAddress { query.ifNoneMatch = tag.etag }
                }
                let answer = try await ask(query)
                guard case .page(let page) = answer else { return .answer(answer) }
                guard page.format == format else { return .answer(.refused(-page.format)) }
                if after == nil { firstTag = page.etag }
                if let version, version != page.version { moved = true; break }
                version = page.version
                rows += page.rows
                after = page.next
            } while after != nil
            if moved { continue }
            return .whole(version: version ?? 0, rows: rows, etag: firstTag, address: firstAddress)
        }
        return .moved
    }

    /// Once a day per source, and never before the time a busy service named.
    static func isDue(_ state: CatalogRowStore.IndexState?, nowMs: Double) -> Bool {
        guard let state else { return true }
        if let notBefore = state.notBeforeMs, nowMs < notBefore { return false }
        return nowMs - state.readAtMs >= dayMs
    }

    /// The sources whose switch is on in this app.
    @MainActor static func sources(_ gates: CatalogGates) -> [CatalogIndexSource] {
        var read: [CatalogIndexSource] = []
        if gates.librivox { read.append(.librivox) }
        if gates.archiveBooks { read += [.archiveBuch, .netlabel, .schellack, .otr] }
        if gates.gutenberg { read.append(.gutenberg) }
        if gates.musopen { read.append(.musopen) }
        return read
    }

    /// Reads every due source of the app from the signed-in service, one
    /// after the other; without Mär Sync nothing runs. A service without a
    /// catalogue is asked again only the next day.
    @MainActor static func runIfDue(store: CatalogRowStore, reader: any MaerSyncCatalogReading = MaerSyncHTTP()) async {
        guard let access = MaerSyncAccess.stored() else { return }
        let ask: Ask = { try await reader.catalog($0, access: access) }
        await runIfDue(store: store, ask: ask, sources: sources(.live))
    }

    /// One run at a time; a start while one runs comes back at once.
    @MainActor private static var running = false

    @MainActor static func runIfDue(store: CatalogRowStore, ask: @escaping Ask, sources: [CatalogIndexSource]) async {
        guard !running else { return }
        running = true
        defer { running = false }
        for source in sources {
            let now = Date().timeIntervalSince1970 * 1000
            let state: CatalogRowStore.IndexState?
            do {
                state = try await store.indexState(source.rawValue)
            } catch {
                Logger.library.error("CATALOG index \(source.rawValue, privacy: .public) state unread: \(FailureReason.of(error), privacy: .public)")
                continue
            }
            guard isDue(state, nowMs: now) else { continue }
            if await run(source, store: store, ask: ask, nowMs: now) == .noCatalog {
                // A service without a catalogue is asked again the next day,
                // not once per source.
                for other in sources where other != source {
                    do { try await store.noteIndexRead(other.rawValue, atMs: now, notBeforeMs: nil) } catch {
                        Logger.library.error("CATALOG index \(other.rawValue, privacy: .public) read not noted: \(FailureReason.of(error), privacy: .public)")
                    }
                }
                return
            }
        }
    }
}
