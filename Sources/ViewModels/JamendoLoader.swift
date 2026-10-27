// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Everything the Jamendo pages load, below the views: it asks Jamendo, maps
/// each track into the catalogue's register and hands back an ANSWER, a
/// failure included. The pages only show what comes back.
@MainActor
enum JamendoLoader {
    typealias Outcome = CatalogLoadOutcome

    /// How long the trove waits before it asks a second time after an
    /// answer without tracks.
    static let emptyAnswerPause: Duration = .milliseconds(1500)

    /// The weekly popularity trove of the Jamendo page. `clients` are the
    /// live ones by default; a witness hands in its own. Jamendo at times
    /// answers success without a single track (measured against the API);
    /// the trove then asks once more after `pause`, and an answer that
    /// stays empty comes back empty for the page to say so.
    static func trove(limit: Int, using clients: CatalogClients = .live,
                      pause: Duration = emptyAnswerPause) async -> Outcome {
        do {
            var tracks = try await clients.jamendo.popularTracks(limit, [], 0, .none)
            if tracks.isEmpty {
                Logger.library.notice("JAMENDO trove answered without tracks, asking once more")
                try await Task.sleep(for: pause)
                tracks = try await clients.jamendo.popularTracks(limit, [], 0, .none)
            }
            return .loaded(items: register(tracks), fetched: tracks.count)
        } catch {
            guard !error.isCancellation else { return .cancelled }
            Logger.library.error("JAMENDO trove FAILED: \(String(describing: error), privacy: .public)")
            return .failed(reason: reason(error))
        }
    }

    /// The genre shelf rows of the Jamendo page, asked in turn. A
    /// failing genre drops out instead of taking the page down, and its
    /// reason comes back so the page can say so when nothing arrived. A
    /// shelf that answered empty stays honestly absent. Each answered
    /// shelf goes to `onShelf` as soon as it arrives, before the next one is
    /// asked, so the page fills row by row.
    static func shelves(using clients: CatalogClients = .live,
                        onShelf: (_ key: String, _ row: [LibraryItem]) -> Void = { _, _ in })
        async -> (rows: [String: [LibraryItem]], failures: [String: String]) {
        let jamendo = clients.jamendo
        // The shelves ask one after the other on the main actor, each
        // without a task of its own. Asked side by side, in a task group or
        // in tasks of their own, an answer comes back with a broken key in
        // the optimized build and the app aborts; one after the other it
        // does not (measured in the simulator). A cancelled page stops
        // asking.
        var rows: [String: [LibraryItem]] = [:]
        var failures: [String: String] = [:]
        for shelf in CatalogGenreAxis.musicShelves {
            guard !Task.isCancelled else { break }
            let key = shelf.key
            do {
                let tracks = try await jamendo.popularTracks(12, CatalogGenreAxis.musicTags(forShelf: key), 0, .none)
                let row = register(tracks)
                rows[key] = row
                onShelf(key, row)
            } catch {
                guard !error.isCancellation else { break }
                let failure = reason(error)
                Logger.library.error("JAMENDO shelf=\(key, privacy: .public) FAILED: \(failure, privacy: .public)")
                failures[key] = failure
            }
        }
        return (rows, failures)
    }

    /// One page of a genre shelf.
    static func shelfPage(shelfKey: String, limit: Int, offset: Int, filter: JamendoFilter,
                          using clients: CatalogClients = .live) async -> Outcome {
        let tags = CatalogGenreAxis.musicTags(forShelf: shelfKey)
        do {
            let tracks = try await clients.jamendo.popularTracks(limit, tags, offset, filter)
            return .loaded(items: register(tracks), fetched: tracks.count)
        } catch {
            guard !error.isCancellation else { return .cancelled }
            Logger.library.error("JAMENDO shelf=\(shelfKey, privacy: .public) offset=\(offset) FAILED: \(String(describing: error), privacy: .public)")
            return .failed(reason: reason(error))
        }
    }

    private static func register(_ tracks: [JamendoTrack]) -> [LibraryItem] {
        let provider = FreeCatalogProvider.shared
        return tracks.compactMap { provider.remember(track: $0) }
    }

    nonisolated private static func reason(_ error: Error) -> String { Outcome.reason(error) }
}
