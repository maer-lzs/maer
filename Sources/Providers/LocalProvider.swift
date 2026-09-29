// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Second AudioProvider: imported local files (no server). Proves the provider
/// abstraction with a source that knows neither login, network nor server-side
/// progress. Progress runs purely locally via the existing `localPosition`
/// mechanism.
@MainActor
final class LocalProvider: AudioProvider {
    static let shared = LocalProvider()
    private let library = LocalLibrary.shared

    private init() {}

    var providerId: String { "local" }
    /// Like the RSS source, availability is CONTENT-driven. The local
    /// source only surfaces the audiobooks tab once files were imported (a
    /// serverless podcasts-first start is not greeted by an empty book tab).
    /// TF bib-toggles: gated by the audiobooks TAB master only. Local downloads
    /// have no server source to toggle and no calls to gate, but the whole-type
    /// switch still hides them (downloads stay playable via search/queue).
    var isAvailable: Bool { AppStorageKeys.audiobooksTabEnabledValue && !library.libraryItems().isEmpty }
    /// No capabilities: no server sync, no server bookmarks, no remote search,
    /// no password login.
    var capabilities: ProviderCapabilities { [.alwaysLocal] }
    var streamAuthHeaders: [String: String] { [:] }

    func fetchLibraries() async throws -> [ABSLibrary] {
        [ABSLibrary(id: "local", name: String(localized: "Local Files"))]
    }

    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        library.libraryItems()
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        guard let detail = library.itemDetail(id: itemId) else {
            throw ItemNotHere.fileGone
        }
        return detail
    }

    func coverURL(forItemId itemId: String) -> URL? {
        library.coverURL(forItemId: itemId)
    }

    func streamURL(forContentPath contentPath: String) -> URL? {
        library.fileURL(forContentPath: contentPath)
    }

    /// Pure (tested): one stored `[time, lastUpdate]` pair + duration → the
    /// progress value. `nil` when the stored shape is not the expected pair.
    nonisolated static func storedProgress(_ stored: [Double]?, duration: Double) -> BookProgress? {
        guard duration > 0, let stored, stored.count >= 2 else { return nil }
        let time = stored[0]
        return BookProgress(
            fraction: min(max(time / duration, 0), 1),
            // The same one rule as everywhere: if the entry knows the
            // duration that applied back then, that one counts. Otherwise
            // today's.
            isFinished: ProgressMark.reachedEnd(stored: stored, currentDuration: duration),
            lastUpdate: stored[1],
            currentTime: time
        )
    }

    /// Progress comes purely locally from `localPosition`. The provider is the
    /// ONLY interface to the outside, the core never reads it itself.
    func fetchAllProgress() async throws -> [String: BookProgress] {
        // Snapshot the item list on the actor, then read the per-item
        // defaults OFF the main actor (UserDefaults is thread-safe). A large
        // local library must not stall the main thread with n plist reads.
        let inputs: [(id: String, duration: Double)] = library.libraryItems().compactMap {
            guard let duration = $0.media?.duration, duration > 0 else { return nil }
            return ($0.id, duration)
        }
        // detached because reading durations is disk work off the MainActor
        return await Task.detached(priority: .userInitiated) {
            var map: [String: BookProgress] = [:]
            for (id, duration) in inputs {
                let stored = ListeningStore.backup(id)
                if let progress = Self.storedProgress(stored, duration: duration) {
                    map[id] = progress
                }
            }
            return map
        }.value
    }

    /// Deliberate no-op: there is no server to push progress to. Positions are
    /// written by the player through the `localPosition` mechanism (the same
    /// store `fetchAllProgress` reads). Writing here too would duplicate the
    /// write path for the same key.
    // Deliberately empty: local progress persists through the player
    // path (PlayerViewModel's local-position save), not through the provider.
    // A second write here would race that one truth. Not a stub.
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}

    // No server bookmarks (capability missing. Never called).
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}
}
