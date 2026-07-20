// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// F1: internet radio as an AudioProvider — namespace `radio:`. Sources: the
/// open Radio Browser catalog (search) + user-entered stream URLs (managed on
/// the radio source page). Capability flags are HONEST: live audio has no
/// seek, no duration, no progress, no download, no chapters — so none of the
/// capabilities apply and the player switches to its live abstraction (F2).
/// Core stays Foundation-only (MaerCore rule).
@MainActor
final class RadioProvider: AudioProvider {
    static let shared = RadioProvider()
    private init() {}

    var providerId: String { "radio" }
    var mediaType: MediaType { .radio }
    var capabilities: ProviderCapabilities { [.remoteSearch] }
    var streamAuthHeaders: [String: String] { [:] }

    /// The radio tab appears once the source is switched on (settings). Like
    /// every source toggle it reacts live (Y37).
    var isAvailable: Bool { AppStorageKeys.radioEnabledValue }

    func fetchLibraries() async throws -> [ABSLibrary] {
        [ABSLibrary(id: "radio", name: String(localized: "Radio"))]
    }

    /// "Library" = favorites + manual stations (the catalog is search-only).
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        (RadioStore.favorites() + RadioStore.manualStations()).map(Self.libraryItem(for:))
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        guard let station = RadioStore.station(forId: itemId) ?? sessionStations[itemId] else {
            throw URLError(.resourceUnavailable)
        }
        // Every play path lands here — record the last-heard ring and the
        // play-frequency count (Teil 3, "Most Played") centrally.
        RadioStore.recordRecent(station)
        RadioStore.recordPlay(station)
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
                                       contentUrl: station.streamURL, metadata: nil)]),
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

    /// No progress for live audio — empty by design (no capability).
    func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}

    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}

    // MARK: - Session catalog cache

    /// Stations surfaced by search this session — keeps catalog hits playable
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

    /// F4: catalog search — live over Radio Browser; offline, favorites and
    /// manual stations filter locally (offline-first like every provider).
    func searchStations(query: String) async -> [RadioStation] {
        let local = (RadioStore.favorites() + RadioStore.manualStations())
            .filter { $0.name.localizedCaseInsensitiveContains(query) }
        guard NetworkMonitor.shared.isConnected else { return local }
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
