// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Testing
@testable import Maer

/// Between the person's tail and the true end a title SHOWS as played, and
/// its played or finished toggle offers "played" there: it writes the end and
/// moves on. Only at the true end (or a server's finished flag) does the
/// toggle offer "unplayed". A toggle that read what the row shows offered
/// "unplayed" in the last minute and wrote 0 over it.
@MainActor
struct MarkGestureAtTrueEndTests {
    private static let duration: Double = 3_600
    private static let tail: Double = 60

    private static func episode(_ id: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: "Folge", authorName: nil, narratorName: nil, seriesName: nil,
                                          genres: nil, publishedYear: nil, description: nil),
            duration: duration, chapters: nil, tracks: nil), addedAt: nil)
    }

    private static var now: Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: - The rule

    @Test("the rule: true end offers unplayed, otherwise played")
    func theRule() {
        #expect(ProgressMark.markGesture(atTrueEnd: true) == .markUnplayed)
        #expect(ProgressMark.markGesture(atTrueEnd: false) == .markPlayed)
        #expect(ProgressMark.MarkGesture.markPlayed.marksPlayed)
        #expect(!ProgressMark.MarkGesture.markUnplayed.marksPlayed)
    }

    // MARK: - Episodes (device mark)

    private static func episodeGesture(entry: [Double]?) -> ProgressMark.MarkGesture {
        let id = "rss:mark-gesture:\(UUID().uuidString)"
        defer { ListeningStore.clearBackup(id) }
        if let entry { ListeningStore.store(id, entry: entry) }
        return podcastMarkGesture(Self.episode(id))
    }

    @Test("episode before the threshold (half played): mark played")
    func episodeBeforeTheTail() {
        #expect(Self.episodeGesture(entry: [1_800, Self.now, Self.duration]) == .markPlayed)
    }

    @Test("episode within the threshold (59:00 of 60:00, threshold 60 s): mark played")
    func episodeWithinTheTail() {
        let entry = [3_540, Self.now, Self.duration]
        // The precondition, assured: the row SHOWS this episode as played.
        #expect(ProgressMark.state(stored: entry, currentDuration: Self.duration, tail: Self.tail) == .played,
                "the row must show the episode as played")
        #expect(Self.episodeGesture(entry: entry) == .markPlayed,
                "within the tail the toggle offers unplayed and writes 0")
    }

    @Test("episode at the true end and with a mark without duration: mark unplayed")
    func episodeAtTheTrueEnd() {
        #expect(Self.episodeGesture(entry: [Self.duration, Self.now, Self.duration]) == .markUnplayed)
        #expect(Self.episodeGesture(entry: [ProgressMark.playedSentinel, Self.now]) == .markUnplayed)
    }

    @Test("episode untouched: mark played")
    func episodeUntouched() {
        #expect(Self.episodeGesture(entry: nil) == .markPlayed)
    }

    @Test("episode within the threshold: the question writes nothing")
    func askingWritesNothing() {
        let id = "rss:mark-gesture-read:\(UUID().uuidString)"
        defer { ListeningStore.clearBackup(id) }
        let entry = [3_540, Self.now, Self.duration]
        ListeningStore.store(id, entry: entry)
        _ = podcastMarkGesture(Self.episode(id))
        #expect(ListeningStore.backup(id) == entry, "asking wrote something")
    }

    // MARK: - Server episodes (the flag the server holds)

    @Test("server episode: flag set is the true end, a fraction within the threshold is not")
    func serverEpisode() {
        let flagged = ProgressMark.serverState(isFinished: true, fraction: 0.5, duration: Self.duration, tail: 0)
        #expect(ProgressMark.markGesture(atTrueEnd: flagged == .played) == .markUnplayed)
        let shown = ProgressMark.serverState(isFinished: false, fraction: 0.99, duration: Self.duration, tail: Self.tail)
        #expect(shown == .played, "the row must show the episode as played")
        let trueEnd = ProgressMark.serverState(isFinished: false, fraction: 0.99, duration: Self.duration, tail: 0)
        #expect(ProgressMark.markGesture(atTrueEnd: trueEnd == .played) == .markPlayed)
    }

    // MARK: - Server books (BookProgress as the library builds it)

    private static func book(fraction: Double, flag: Bool) -> BookProgress {
        BookProgress(fraction: fraction, isFinished: flag, lastUpdate: 0, currentTime: fraction * duration)
            .judged(duration: duration, tail: tail)
    }

    @Test("server book before the threshold, within the threshold, at the true end, with flag")
    func serverBook() {
        #expect(Self.book(fraction: 0.5, flag: false).markGesture == .markPlayed)
        let inTail = Self.book(fraction: 3_540 / Self.duration, flag: false)
        #expect(inTail.countsAsFinished, "the row must show the book as finished")
        #expect(inTail.markGesture == .markPlayed)
        #expect(Self.book(fraction: 1, flag: false).markGesture == .markUnplayed,
                "numbers that say complete are the true end")
        #expect(Self.book(fraction: 0.2, flag: true).markGesture == .markUnplayed,
                "the server's flag is the true end")
    }

    // MARK: - Catalog books (mark on the device)

    @Test("catalog book: flag is the true end, the threshold stands beside it")
    func catalogBook() {
        func progress(_ position: Double, marked: Double? = Self.duration) -> BookProgress {
            BookProgress.fromDeviceMark(position: position, updatedAtMs: Self.now, markedDuration: marked,
                                        itemDuration: Self.duration, tail: Self.tail)
        }
        #expect(progress(1_800).markGesture == .markPlayed)
        let inTail = progress(3_540)
        #expect(inTail.countsAsFinished, "the page must show the book as finished")
        #expect(!inTail.isFinished)
        #expect(inTail.markGesture == .markPlayed)
        #expect(progress(Self.duration).markGesture == .markUnplayed)
        #expect(progress(ProgressMark.playedSentinel, marked: nil).markGesture == .markUnplayed)
    }

    // MARK: - Fence: every toggle in a view asks the rule

    /// The labels that offer the way back. Each site shows one of them.
    static let unmarkLabels = ["\"Mark as Unplayed\"", "\"Mark as Unfinished\"", "\"Mark Unfinished\""]

    /// The forms a toggle took when it read what the row shows.
    static let readsTheDisplay = ["podcastSetPlayed(item, !", "= !isFinished", "!(entry.progress?.isFinished"]

    /// Per label site in a text: whether its line reads `.marksPlayed`.
    /// Comment lines do not count. A `switch` whose head reads
    /// `.marksPlayed` is one asked site, however many of its `case` lines
    /// carry a label (the long and the short word of one button).
    static func labelSites(in text: String) -> (asked: Int, unasked: Int) {
        var asked = 0, unasked = 0
        var inAskingSwitch = false
        var switchCounted = false
        for line in text.components(separatedBy: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { continue }
            if code.contains("switch"), code.contains(".marksPlayed") {
                inAskingSwitch = true
                switchCounted = false
                continue
            }
            if inAskingSwitch {
                if code.hasPrefix("case ") || code.hasPrefix("default") {
                    if !switchCounted, unmarkLabels.contains(where: code.contains) {
                        asked += 1
                        switchCounted = true
                    }
                    continue
                }
                inAskingSwitch = false
            }
            guard unmarkLabels.contains(where: code.contains) else { continue }
            if code.contains(".marksPlayed") { asked += 1 } else { unasked += 1 }
        }
        return (asked, unasked)
    }

    /// Lines that take a toggle's direction from the shown state.
    static func displayReads(in text: String) -> Int {
        text.components(separatedBy: "\n").filter { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            return !code.hasPrefix("//") && readsTheDisplay.contains(where: code.contains)
        }.count
    }

    @Test("the counter sees old and new form")
    func theCounterSeesBothForms() {
        let old = "Label(isPlayed ? String(localized: \"Mark as Unplayed\") : String(localized: \"Mark as Played\"))\npodcastSetPlayed(item, !isPlayed)"
        let new = "Label(gesture.marksPlayed ? String(localized: \"Mark as Played\") : String(localized: \"Mark as Unplayed\"))\npodcastSetPlayed(item, gesture.marksPlayed)"
        let comment = "// Label(isPlayed ? \"Mark as Unplayed\" : \"Mark as Played\")\n// podcastSetPlayed(item, !isPlayed)"
        #expect(Self.labelSites(in: old).unasked == 1)
        #expect(Self.displayReads(in: old) == 1)
        #expect(Self.labelSites(in: new).asked == 1)
        #expect(Self.labelSites(in: new).unasked == 0)
        #expect(Self.displayReads(in: new) == 0)
        #expect(Self.labelSites(in: comment).asked + Self.labelSites(in: comment).unasked == 0)
        #expect(Self.displayReads(in: comment) == 0)
        // One button, two words, chosen by the rule: one asked site.
        let switched = """
        let title = switch (gesture.marksPlayed, compact) {
        case (true, false): String(localized: "Mark as Finished")
        case (false, false): String(localized: "Mark as Unfinished")
        case (true, true): String(localized: "Mark Finished")
        case (false, true): String(localized: "Mark Unfinished")
        }
        """
        #expect(Self.labelSites(in: switched).asked == 1)
        #expect(Self.labelSites(in: switched).unasked == 0)
        // The same switch on the shown state asks nothing.
        let shown = switched.replacingOccurrences(of: "gesture.marksPlayed", with: "!isFinished")
        #expect(Self.labelSites(in: shown).asked == 0)
        #expect(Self.labelSites(in: shown).unasked == 2)
    }

    @Test("every toggle gesture in a view asks the rule", .needsTheSources)
    func everyToggleAsksTheRule() throws {
        let views = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(!views.isEmpty, "no view source was read")
        var asked = 0
        var offenders: [String] = []
        for file in views {
            let text = try String(contentsOf: file, encoding: .utf8)
            let sites = Self.labelSites(in: text)
            asked += sites.asked
            if sites.unasked > 0 || Self.displayReads(in: text) > 0 { offenders.append(file.lastPathComponent) }
            // A file with a toggle must hold a call of the rule.
            if sites.asked > 0, !(text.contains("podcastMarkGesture(") || text.contains("markGesture")) {
                offenders.append("\(file.lastPathComponent) (no rule call)")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
        // Episode row swipe, episode menu, episode page, book page, book
        // grid menu, player. A seventh site is a new toggle and belongs here.
        #expect(asked == 6, "\(asked)")
    }
}
