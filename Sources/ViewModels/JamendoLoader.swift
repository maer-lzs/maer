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

    /// The one question this loader asks the network. The live one by
    /// default; a witness hands in its own and runs the loader offline.
    struct Client: Sendable {
        var popularTracks: @Sendable (_ limit: Int, _ tags: [String], _ offset: Int,
                                      _ filter: JamendoFilter) async throws -> [JamendoTrack]

        static let live = Client { limit, tags, offset, filter in
            try await JamendoClient.popularTracks(limit: limit, tags: tags, offset: offset, filter: filter)
        }
    }

    /// The weekly popularity trove of the Jamendo page.
    static func trove(limit: Int, using client: Client = .live) async -> Outcome {
        do {
            let tracks = try await client.popularTracks(limit, [], 0, .none)
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
    static func shelves(using client: Client = .live) async -> (rows: [String: [LibraryItem]], failures: [String: String]) {
        // Tracks (Sendable) cross the group boundary; the mapping runs
        // afterwards on the main actor.
        let answers = await withTaskGroup(of: (String, [JamendoTrack], String?).self) { group in
            for shelf in CatalogGenreAxis.musicShelves {
                let key = shelf.key
                group.addTask {
                    let tags = CatalogGenreAxis.musicTags(forShelf: key)
                    do {
                        return (key, try await client.popularTracks(12, tags, 0, .none), nil)
                    } catch {
                        return (key, [], error.isCancellation ? nil : reason(error))
                    }
                }
            }
            var out: [(String, [JamendoTrack], String?)] = []
            for await answer in group { out.append(answer) }
            return out
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
                          using client: Client = .live) async -> Outcome {
        let tags = CatalogGenreAxis.musicTags(forShelf: shelfKey)
        do {
            let tracks = try await client.popularTracks(limit, tags, offset, filter)
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
