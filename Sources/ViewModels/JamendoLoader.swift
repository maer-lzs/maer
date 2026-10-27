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

    /// The weekly popularity trove of the Jamendo page. `clients` are the
    /// live ones by default; a witness hands in its own.
    static func trove(limit: Int, using clients: CatalogClients = .live) async -> Outcome {
        do {
            let tracks = try await clients.jamendo.popularTracks(limit, [], 0, .none)
            return .loaded(items: register(tracks), fetched: tracks.count)
        } catch {
            guard !error.isCancellation else { return .cancelled }
            Logger.library.error("JAMENDO trove FAILED: \(String(describing: error), privacy: .public)")
            return .failed(reason: reason(error))
        }
    }

    /// The genre shelf rows of the Jamendo page, asked concurrently. A
    /// failing genre drops out instead of taking the page down, and its
    /// reason comes back so the page can say so when nothing arrived. A
    /// shelf that answered empty stays honestly absent.
    static func shelves(using clients: CatalogClients = .live) async -> (rows: [String: [LibraryItem]], failures: [String: String]) {
        let jamendo = clients.jamendo
        // One task per shelf, started together and awaited in turn, without
        // a task group: a group here ends while a child still runs, and the
        // child's end aborts the app (`__cxa_pure_virtual` in
        // `completeFuture`). A cancelled page cancels the asks. Tracks
        // (Sendable) cross into the tasks; the mapping runs afterwards on
        // the main actor.
        let asks = CatalogGenreAxis.musicShelves.map { shelf in
            let key = shelf.key
            return (key, Task { () -> (String, [JamendoTrack], String?) in
                let tags = CatalogGenreAxis.musicTags(forShelf: key)
                do {
                    return (key, try await jamendo.popularTracks(12, tags, 0, .none), nil)
                } catch {
                    return (key, [], error.isCancellation ? nil : reason(error))
                }
            })
        }
        let answers = await withTaskCancellationHandler {
            var out: [(String, [JamendoTrack], String?)] = []
            for (_, ask) in asks { out.append(await ask.value) }
            return out
        } onCancel: {
            for (_, ask) in asks { ask.cancel() }
        }
        var rows: [String: [LibraryItem]] = [:]
        var failures: [String: String] = [:]
        for (key, tracks, failure) in answers {
            if let failure {
                Logger.library.error("JAMENDO shelf=\(key, privacy: .public) FAILED: \(failure, privacy: .public)")
                failures[key] = failure
                continue
            }
            rows[key] = register(tracks)
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
