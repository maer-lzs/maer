// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// b81949f: fills the runtime gaps of the free-audiobook cards. The
/// popularity search (`advancedsearch`) carries `runtime` for MOST items but
/// not all — and the owner did not accept a reserved empty line, rightly.
///
/// **Source chosen after measuring, not guessing:** archive.org's metadata
/// endpoint, because the item `identifier` is already in hand (the card came
/// from that very search) — the LibriVox API has no lookup by
/// `url_iarchive`, so matching would mean guessing via author/title.
/// Accuracy checked against LibriVox's own `totaltimesecs`: 15731 s vs.
/// 15733 s on a 4:22 h book. One roundtrip per gap, lazily, cached — the
/// `FeedArtworkService` pattern, sharing its cache mechanism.
actor ArchiveRuntimeService {
    static let shared = ArchiveRuntimeService()

    private var cache: [String: Double?] = [:]
    private var loaded = false
    private let store = ResolutionCacheStore<Double>(key: "archiveRuntimeSeconds")

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        cache = store.load()
    }

    /// Total runtime of an archive.org item in seconds; nil when unknown.
    func runtimeSeconds(identifier: String) async -> Double? {
        loadIfNeeded()
        if let cached = cache[identifier] { return cached }
        guard await NetworkMonitor.shared.isConnected else { return nil }
        do {
            let response = try await ArchiveOrgClient.metadata(identifier: identifier)
            let files = (response.files ?? []).map { (format: $0.format, length: $0.length) }
            let seconds = FreeCatalog.runtimeSeconds(fromFiles: files)
            cache[identifier] = seconds
            store.store(seconds.map { .found($0) } ?? .absent, for: identifier)
            Logger.library.notice("FREECAT runtime \(identifier, privacy: .public) → \(seconds.map { String(Int($0)) } ?? "absent", privacy: .public)")
            return seconds
        } catch {
            // 95c5c16 rule: a failed lookup is NOT a finding — nothing is
            // written down, not even in the session cache.
            Logger.library.notice("FREECAT runtime \(identifier, privacy: .public) → fetch-failed")
            return nil
        }
    }
}
