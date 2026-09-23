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

    /// The weekly popularity trove of the Jamendo page.
    static func trove(limit: Int) async -> Outcome {
        do {
            let tracks = try await JamendoClient.popularTracks(limit: limit)
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
    static func shelves() async -> (rows: [String: [LibraryItem]], failures: [String: String]) {
        // Tracks (Sendable) cross the group boundary; the mapping runs
        // afterwards on the main actor.
        let answers = await withTaskGroup(of: (String, [JamendoTrack], String?).self) { group in
            for shelf in CatalogGenreAxis.musicShelves {
                let key = shelf.key
                group.addTask {
                    let tags = CatalogGenreAxis.musicTags(forShelf: key)
                    do {
                        return (key, try await JamendoClient.popularTracks(limit: 12, tags: tags), nil)
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
    static func shelfPage(shelfKey: String, limit: Int, offset: Int, filter: JamendoFilter) async -> Outcome {
        let tags = CatalogGenreAxis.musicTags(forShelf: shelfKey)
        do {
            let tracks = try await JamendoClient.popularTracks(limit: limit, tags: tags,
                                                               offset: offset, filter: filter)
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

    /// The catalogue's own sentence where it has one, else the one rule for
    /// a failure's log reason. The pages never show this as a sentence; it
    /// names the failure in the log and marks that something failed.
    nonisolated private static func reason(_ error: Error) -> String {
        FreeCatalog.failureReason(error) ?? FailureReason.of(error)
    }
}
