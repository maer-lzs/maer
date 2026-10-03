// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Fills the runtime gaps of the free-audiobook cards. The
/// popularity search (`advancedsearch`) carries `runtime` for MOST items but
/// not all. A permanently reserved empty line in the card is not an option.
///
/// **Source chosen after measuring, not guessing:** archive.org's metadata
/// endpoint, because the item `identifier` is already in hand (the card came
/// from that very search). The LibriVox API has no lookup by
/// `url_iarchive`, so matching would mean guessing via author/title.
/// Accuracy checked against LibriVox's own `totaltimesecs`: 15731 s vs.
/// 15733 s on a 4:22 h book. One roundtrip per gap, lazily, cached. The
/// `FeedArtworkService` pattern, sharing its cache mechanism.
///
/// An answer is kept for good, the "none" included: an item's files do
/// not change, and a tile asked again every week is a request the service
/// pays for nothing. A failed question is no answer and is not written
/// down, but it counts as asked for the rest of the session, so a tile
/// that comes back asks nothing again.
actor ArchiveRuntimeService {
    static let shared = ArchiveRuntimeService()

    /// The one way out, so a witness counts the questions without a network.
    struct Wire: Sendable {
        var files: @Sendable (String) async throws -> [(format: String?, length: String?)]

        static let live = Wire(files: { identifier in
            // A tile's runtime is an automatic question.
            let response = try await LookupOccasion.automatic {
                try await ArchiveOrgClient.metadata(identifier: identifier)
            }
            return (response.files ?? []).map { (format: $0.format, length: $0.length) }
        })
    }

    /// Ten years: long enough to mean "for good" for a found runtime and
    /// for a "none" alike.
    static let keptFor: TimeInterval = 10 * 365 * 24 * 3600

    private let wire: Wire
    private let defaults: UserDefaults
    private var cache: [String: Double?] = [:]
    private var askedThisSession: Set<String> = []
    private var loaded = false
    private let store = ResolutionCacheStore<Double>(
        key: "archiveRuntimeSeconds", positiveTTL: keptFor, negativeTTL: keptFor)

    /// `suiteName` gives a witness its own defaults; nil is the app's.
    init(wire: Wire = .live, suiteName: String? = nil) {
        self.wire = wire
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        cache = store.load(defaults: defaults)
    }

    /// The lookups in flight. The cache is written from the lookup, not from
    /// the return to the card: a card scrolled away no longer loses the
    /// answer its lookup brings.
    private let lookups = CoalescedFlights<Double?>(capacity: .none)

    /// Total runtime of an archive.org item in seconds; nil when unknown.
    func runtimeSeconds(identifier: String) async -> Double? {
        loadIfNeeded()
        if let cached = cache[identifier] { return cached }
        if askedThisSession.contains(identifier) { return nil }
        guard await Reachability.isConnected() else { return nil }
        // A tile stays a moment before the flight starts (`TileDwell`), in
        // the tile's own task: a tile that left asks nothing and books nothing.
        guard await TileDwell.stood(TileDwell.lookup) else { return nil }
        // bearable, because the failure is already named in `lookup` and a caller that left needs no answer
        return try? await lookups.value(for: identifier) { [self] in
            (try await self.lookup(identifier), 0)
        }
    }

    private func lookup(_ identifier: String) async throws -> Double? {
        do {
            let files = try await wire.files(identifier)
            let seconds = FreeCatalog.runtimeSeconds(fromFiles: files)
            cache[identifier] = seconds
            store.store(seconds.map { .found($0) } ?? .absent, for: identifier, defaults: defaults)
            Logger.library.notice("FREECAT runtime \(identifier, privacy: .public) → \(seconds.map { String(Int($0)) } ?? "absent", privacy: .public)")
            return seconds
        } catch {
            // Ended before anything was asked (held back after a failure, or
            // the host resting): not booked as asked, so a tile that comes
            // back afterwards asks once.
            if error.endedUnasked { throw error }
            // A caller that left is not a failure; the next tile asks.
            if !error.isCancellation { askedThisSession.insert(identifier) }
            // A failed lookup is NOT a finding: nothing is written down,
            // it only counts as asked for this session.
            Logger.library.notice("FREECAT runtime \(identifier, privacy: .public) → fetch-failed reason=\(ArchiveOrgClient.fetchReason(error), privacy: .public)")
            throw error
        }
    }
}
