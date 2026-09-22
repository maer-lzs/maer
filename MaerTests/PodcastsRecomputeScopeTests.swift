// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Podcasts tab fills its sections in `.task(id: recomputeToken)`; the
/// token must move when the subscription list moves, whoever moved it: a
/// subscription adopted from the account in the background takes the same
/// path as one the person subscribed by hand. Without a move the grid stands
/// until the next app start.
struct PodcastsRecomputeScopeTests {
    @Test("Adoption aus dem Konto bewegt den Recompute-Token wie ein Abonnieren von Hand; ohne Aenderung bleibt er")
    @MainActor
    func adoptionMovesTheToken() async throws {
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        subs._testSetLoaded(true)
        let scope = PodcastsRecomputeScope.shared
        let feedURL = "https://example.org/recompute-\(UUID().uuidString.prefix(8))/feed.xml"
        subs._testFeedFetcher = { url in
            .show(PodcastShow(id: PodcastSubscriptions.feedKey(url.absoluteString), title: "Adopted",
                              author: nil, artworkURL: nil, description: nil,
                              feedURL: url.absoluteString, episodes: []))
        }
        defer {
            subs._testFeedFetcher = nil
            subs.removeMirrored(feedURL: feedURL)
        }
        func settle(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<100 where !condition() {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        // Rot-Probe: no change, no move (a settled token stays).
        try await Task.sleep(nanoseconds: 50_000_000)
        let before = scope.token
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(scope.token == before, "a token without a change must stand")

        subs.adoptCloudSubscriptions(added: [(feedURL: feedURL, t: 1)], removed: [])
        try await settle { subs.shows.contains { $0.feedURL == feedURL } }
        try await settle { scope.token != before }
        #expect(scope.token != before, "an adopted subscription must move the token")

        // And the way back: the show leaves, the token moves again.
        let held = scope.token
        subs.removeMirrored(feedURL: feedURL)
        try await settle { scope.token != held }
        #expect(scope.token != held)
    }

    /// An entry that arrives from outside the podcast store (a local start,
    /// a takeover, a pot adoption) reaches the tab through the listening
    /// revision. Rot-Probe: without a bump the token stands.
    @Test("Ein Stoss der Hoer-Revision bewegt den Token; ohne Stoss steht er")
    @MainActor
    func revisionBumpMovesTheToken() async throws {
        let scope = PodcastsRecomputeScope.shared
        try await Task.sleep(nanoseconds: 50_000_000)
        let before = scope.token
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(scope.token == before, "no event, no move")
        ListeningRevision.shared.bump("test entry from outside")
        for _ in 0..<50 where scope.token == before {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(scope.token != before, "a revision bump must move the token")
    }

    /// The pages that filter by downloads key their computation on this
    /// token, so a finished or deleted download must move it, and so must a
    /// download swapped at equal count. Before, two of them keyed on the
    /// number of shows and stayed on yesterday's grid.
    @Test("Ein Download, der kommt, geht oder bei gleicher Zahl getauscht wird, bewegt den Token")
    func aChangedDownloadMovesTheToken() {
        let feeds = ["https://example.org/a.xml"]
        let counters = ["1", "2", "3"]
        let token = { (ids: Set<String>) in
            PodcastsRecomputeScope.token(feedURLs: feeds, downloadedIds: ids, counters: counters)
        }
        let base = token(["ep-1", "ep-2"])
        #expect(token(["ep-1", "ep-2"]) == base, "ohne Aenderung steht er")
        #expect(token(["ep-1", "ep-2", "ep-3"]) != base, "ein fertiger Download")
        #expect(token(["ep-1"]) != base, "ein geloeschter Download")
        #expect(token(["ep-1", "ep-9"]) != base, "getauscht bei gleicher Zahl")

        let id = PodcastsRecomputeScope.taskID(token: base, extra: "newest-mitDownloads")
        #expect(PodcastsRecomputeScope.taskID(token: token(["ep-1"]), extra: "newest-mitDownloads") != id)
        #expect(PodcastsRecomputeScope.taskID(token: base, extra: "newest-alle") != id,
                "Sortierung und Filter der Seite gehoeren zur Kennung")
    }

    /// Every task in the podcast pages that computes the snapshot (and with
    /// it the downloaded set) runs through `taskOnPodcastChange`, never through
    /// a `.task` of its own that the download set cannot move.
    @Test("Jede Podcast-Seite, die den Schnappschuss rechnet, haengt an der Kennung", .needsTheSources)
    func everySnapshotTaskHangsOnTheToken() throws {
        let text = try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/Views/PodcastsView.swift"), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var ownTasks: [Int] = []
        var keyed = 0
        for (index, line) in lines.enumerated() {
            let window = lines[index..<min(index + 4, lines.count)].joined(separator: "\n")
            guard window.contains("PodcastSections.snapshot(") else { continue }
            if line.contains(".taskOnPodcastChange") { keyed += 1 }
            if line.contains(".task(") || line.contains(".task {") { ownTasks.append(index + 1) }
        }
        #expect(ownTasks.isEmpty, "eine Seite rechnet den Schnappschuss in einer eigenen .task: Zeilen \(ownTasks)")
        #expect(keyed == 3, "drei Seiten rechnen den Schnappschuss direkt in ihrer Aufgabe, gezaehlt \(keyed)")
    }
}
#endif
