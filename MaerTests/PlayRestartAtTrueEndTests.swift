// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Testing
@testable import Maer

/// A deliberate Play starts an episode from the beginning only at its TRUE
/// end. Within the person's tail the episode SHOWS as played, and the
/// last minute must still be playable from where it stands: a restart there
/// wrote 0 and sent it to every device.
@MainActor
struct PlayRestartAtTrueEndTests {
    private static let duration: Double = 3_600

    private static func episode(_ id: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: "Folge", authorName: nil, narratorName: nil, seriesName: nil,
                                          genres: nil, publishedYear: nil, description: nil),
            duration: duration, chapters: nil, tracks: nil), addedAt: nil)
    }

    private static var now: Double { Date().timeIntervalSince1970 * 1000 }

    @Test("position 59:00 of 60:00, threshold 60 s: play resumes and writes nothing")
    func withinTheTailPlayResumes() {
        let id = "rss:play-tail:\(UUID().uuidString)"
        defer { ListeningStore.clearBackup(id) }
        let entry = [3_540, Self.now, Self.duration]
        ListeningStore.store(id, entry: entry)
        // The precondition, assured: with a tail of 60 s the row SHOWS this
        // episode as played. Without that the case would measure nothing.
        #expect(ProgressMark.state(stored: entry, currentDuration: Self.duration, tail: 60) == .played,
                "the row must show the episode as played")

        #expect(!podcastRestartsOnPlay(Self.episode(id)), "a Play within the tail restarts at 0")
        #expect(ListeningStore.backup(id) == entry, "asking wrote something")
    }

    @Test("true end: play starts from the beginning as before")
    func atTheTrueEndPlayRestarts() {
        let id = "rss:play-end:\(UUID().uuidString)"
        defer { ListeningStore.clearBackup(id) }
        ListeningStore.store(id, entry: [Self.duration, Self.now, Self.duration])
        #expect(podcastRestartsOnPlay(Self.episode(id)), "a finished episode no longer restarts")
    }

    @Test("marked as played (mark without duration): play starts from the beginning as before")
    func theMarkedPlayedSentinelRestarts() {
        let id = "rss:play-mark:\(UUID().uuidString)"
        defer { ListeningStore.clearBackup(id) }
        ListeningStore.store(id, entry: [ProgressMark.playedSentinel, Self.now])
        #expect(podcastRestartsOnPlay(Self.episode(id)), "a marked episode no longer restarts")
    }

    @Test("untouched and half played: play resumes")
    func unplayedAndHalfHeardResume() {
        let half = "rss:play-half:\(UUID().uuidString)"
        defer { ListeningStore.clearBackup(half) }
        ListeningStore.store(half, entry: [1_800, Self.now, Self.duration])
        #expect(!podcastRestartsOnPlay(Self.episode(half)), "a half-heard episode restarts")
        #expect(!podcastRestartsOnPlay(Self.episode("rss:play-none:\(UUID().uuidString)")),
                "an untouched episode restarts")
    }

    // MARK: - Fence: no view decides a restart from what it shows

    /// Per `restart: true` in a view: whether the five lines before it ask
    /// `podcastRestartsOnPlay(`. Local on purpose: a call forty lines up must
    /// not excuse a restart next to it. Comment lines do not count.
    static func restartSites(in text: String) -> (asked: Int, unasked: Int) {
        let lines = text.components(separatedBy: "\n")
        var asked = 0, unasked = 0
        for (index, line) in lines.enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), code.contains("restart: true") else { continue }
            let before = lines[max(0, index - 5)..<index]
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            if before.contains(where: { $0.contains("podcastRestartsOnPlay(") }) { asked += 1 } else { unasked += 1 }
        }
        return (asked, unasked)
    }

    @Test("the counter sees both forms")
    func theCounterSeesBothForms() {
        let old = "} else if podcastPlayState(for: item) == .played {\n    podcastSetPlayed(item, false)\n    await c.open(item: item, restart: true)\n}"
        let new = "} else if podcastRestartsOnPlay(item) {\n    podcastSetPlayed(item, false)\n    await c.open(item: item, restart: true)\n}"
        let comment = "if podcastRestartsOnPlay(item) {\n    // open(item: item, restart: true)\n}"
        let oldSites = Self.restartSites(in: old)
        let newSites = Self.restartSites(in: new)
        let commentSites = Self.restartSites(in: comment)
        #expect(oldSites.asked == 0)
        #expect(oldSites.unasked == 1)
        #expect(newSites.asked == 1)
        #expect(newSites.unasked == 0)
        #expect(commentSites.asked + commentSites.unasked == 0)
    }

    @Test("every restart in a view asks the true end", .needsTheSources)
    func everyRestartInAViewAsksTheTrueEnd() throws {
        let views = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(!views.isEmpty, "no view source was read")
        var asked = 0
        var offenders: [String] = []
        for file in views {
            let sites = Self.restartSites(in: try String(contentsOf: file, encoding: .utf8))
            asked += sites.asked
            if sites.unasked > 0 { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "\(offenders)")
        // The two Play buttons of an episode (row and page). A third site is
        // a new way to restart and belongs to this fence.
        #expect(asked == 2, "\(asked)")
    }
}
