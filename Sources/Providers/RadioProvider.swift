// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Internet radio as an AudioProvider. Namespace `radio:`. Sources: the
/// open Radio Browser catalog (search) + user-entered stream URLs (managed on
/// the radio source page). Capability flags are HONEST: live audio has no
/// seek, no duration, no progress, no download, no chapters. So none of the
/// capabilities apply and the player switches to its live abstraction.
/// Core stays Foundation-only (MaerCore rule).
@MainActor
final class RadioProvider: AudioProvider {
    static let shared = RadioProvider()
    private init() {}

    var providerId: String { "radio" }
    var mediaTypes: Set<MediaType> { [.radio] }
    var keepsMarksOnDevice: Bool { true }
    var capabilities: ProviderCapabilities { [.remoteSearch] }
    var streamAuthHeaders: [String: String] { [:] }

    /// The radio tab appears once the source is switched on (settings). Like
    /// every source toggle it reacts live.
    var isAvailable: Bool { AppStorageKeys.radioActive }

    func fetchLibraries() async throws -> [ABSLibrary] {
        [ABSLibrary(id: "radio", name: String(localized: "Radio"))]
    }

    /// "Library" = favorites + manual stations (the catalog is search-only).
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        (RadioStore.favorites() + RadioStore.manualStations()).map(Self.libraryItem(for:))
    }

    /// The last-heard ring and the play-frequency count (Teil 3, "Most Played").
    ///
    /// This is deliberately NOT in `fetchItemDetail`: resolving an item is not
    /// listening to it. The same resolution serves the bounded server check, the
    /// sync refresh and the restore after an app start. A station kept as the
    /// last item scored a play on every launch, with nothing playing.
    func notePlaybackStarted(itemId: String) {
        guard let station = RadioStore.station(forId: itemId) ?? sessionStations[itemId] else { return }
        RadioStore.recordRecentNoting(station)
        RadioStore.recordPlay(station)
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        guard let station = RadioStore.station(forId: itemId) ?? sessionStations[itemId] else {
            throw URLError(.resourceUnavailable)
        }
        // Teil 1: honor the user's per-station variant choice (else the best).
        let streamURL = RadioMapping.effectiveStreamURL(
            for: station, selectedURL: RadioStore.selectedVariantURL(for: station))
        // What actually plays (vs the tap line above), and the icy-name check
        // against the tile name (log only), which catches app-side swaps AND
        // hijacked catalog entries. The check is one more request per play,
        // so it runs where its log is read: behind the measuring gate (Xcode,
        // TestFlight), never in the App Store.
        let isVariantChoice = streamURL != station.streamURL
        Logger.library.notice("RADIO play id=\(itemId, privacy: .public) name=\(station.name, privacy: .public) stream=\(streamURL, privacy: .public) variant=\(isVariantChoice ? "chosen" : "default", privacy: .public)")
        if MetricReceiver.isOn {
            RadioDiagnostics.compareICYName(streamURL: streamURL, expectedName: station.name,
                                            stationID: station.id)
        } else {
            // The gate is closed, or not decided yet on a cold start from
            // Siri or a shortcut: the check does not run, the play does not
            // wait for the gate, and the line says which of the two it was.
            Logger.library.notice("RADIO icy-check skipped gate=\(MetricReceiver.decision.rawValue, privacy: .public) id=\(itemId, privacy: .public)")
        }
        // One "track" pointing at the live stream; no duration, no chapters.
        return LibraryItemDetail(
            id: station.id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: station.name, authorName: nil, narratorName: nil,
                    seriesName: nil, genres: station.tags.isEmpty ? nil : station.tags,
                    publishedYear: nil, description: nil),
                duration: nil, chapters: nil,
                tracks: [ABSAudioTrack(index: 0, startOffset: 0, duration: nil,
                                       contentUrl: streamURL, metadata: nil)]),
            userMediaProgress: nil)
    }

    func coverURL(forItemId itemId: String) -> URL? {
        guard let station = RadioStore.station(forId: itemId) ?? sessionStations[itemId],
              let favicon = station.faviconURL else { return nil }
        return URL(string: favicon)
    }

    /// Radio content paths ARE absolute stream URLs.
    func streamURL(forContentPath contentPath: String) -> URL? {
        URL(string: contentPath)
    }

    /// No progress for live audio. Empty by design (no capability).
    func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}

    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}

    // MARK: - Session catalog cache

    /// Stations surfaced by search this session. Keeps catalog hits playable
    /// and resolvable (favorites/manual persist in RadioStore instead).
    private(set) var sessionStations: [String: RadioStation] = [:]

    func remember(_ stations: [RadioStation]) {
        for station in stations { sessionStations[station.id] = station }
    }

    func station(forId id: String) -> RadioStation? {
        RadioStore.station(forId: id) ?? sessionStations[id]
    }

    func libraryItem(forId id: String) -> LibraryItem? {
        station(forId: id).map(Self.libraryItem(for:))
    }

    nonisolated static func libraryItem(for station: RadioStation) -> LibraryItem {
        LibraryItem(id: station.id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: station.name, authorName: nil, narratorName: nil,
                seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: nil, chapters: nil, tracks: nil), addedAt: 0)
    }

    /// Catalog search. Live over Radio Browser; offline, favorites and
    /// manual stations filter locally (offline-first like every provider).
    func searchStations(query: String) async -> [RadioStation] {
        let local = (RadioStore.favorites() + RadioStore.manualStations())
            .filter { $0.name.localizedCaseInsensitiveContains(query) }
        guard await Reachability.isConnected() else { return local }
        let remote = (try? await RadioBrowserClient.search(name: query)) ?? []
        remember(remote)
        var seen = Set(local.map(\.id))
        return local + remote.filter { seen.insert($0.id).inserted }
    }
}

extension RadioProvider: SearchableProvider {
    @MainActor
    func search(query: String) async throws -> [SearchResult] {
        #if DEBUG
        if UITestSeed.isActive {
            return UITestSeed.seedRadioStations
                .filter { $0.name.localizedCaseInsensitiveContains(query) }
                .map { SearchResult(id: $0.id, kind: .radioStation, title: $0.name) }
        }
        #endif
        return await searchStations(query: query).map { station in
            SearchResult(id: station.id, kind: .radioStation, title: station.name,
                         subtitle: station.tags.first,
                         coverURL: station.faviconURL.flatMap { URL(string: $0) })
        }
    }
}
