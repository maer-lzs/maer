// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The pages of the Musopen catalog: one answer at a time from where the
/// reader stands, through the three categories, each recording remembered
/// for playback. The files the licence rule and the player leave out are
/// counted in the log line, per reason.
@MainActor
enum MusopenLoader {
    typealias Outcome = CatalogLoadOutcome

    /// Whether the catalog was read in this run, to its end or to its
    /// limit: the end of a movement then reads it no second time.
    static var musopenReadToEnd = false

    /// Every answer in turn, within the limit, for the page and for the end
    /// of a movement alike; a reading that ended without failure counts as
    /// read. A page left in the middle of its reading does not count.
    static func readAll(_ start: MusopenPageReading = MusopenPageReading(),
                        show: (MusopenPageReading) -> Void = { _ in }) async -> MusopenPageReading {
        let reading = await MusopenPageReading.readAll(start, maxAnswers: MusopenCatalog.readingLimit,
                                                       fetch: { await next(from: $0) }, show: show)
        if !Task.isCancelled { musopenReadToEnd = !reading.failed }
        return reading
    }

    static func next(from cursor: MusopenCatalog.Cursor, using clients: CatalogClients = .live)
        async -> (outcome: Outcome, next: MusopenCatalog.Cursor?) {
        do {
            let answer = try await clients.musopen.next(cursor)
            let dropped = MusopenCatalog.Dropped.allCases.map { "\($0.rawValue)=\(answer.page.dropped[$0] ?? 0)" }.joined(separator: " ")
            Logger.library.notice("MUSOPEN page category=\(cursor.category) loaded=\(answer.page.recordings.count) \(dropped, privacy: .public)")
            let provider = FreeCatalogProvider.shared
            let items = answer.page.recordings.compactMap { provider.remember(recording: $0) }
            let fetched = answer.page.recordings.count + answer.page.dropped.values.reduce(0, +)
            return (.loaded(items: items, fetched: fetched), answer.next)
        } catch {
            guard !error.isCancellation else { return (.cancelled, cursor) }
            Logger.library.error("MUSOPEN page FAILED: \(String(describing: error), privacy: .public)")
            return (.failed(reason: Outcome.reason(error)), cursor)
        }
    }
}
