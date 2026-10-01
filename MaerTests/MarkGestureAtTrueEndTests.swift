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

    @Test("die Regel: echtes Ende bietet ungehoert, sonst gehoert")
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

    @Test("Folge vor der Schwelle (halb gehoert): gehoert markieren")
    func episodeBeforeTheTail() {
        #expect(Self.episodeGesture(entry: [1_800, Self.now, Self.duration]) == .markPlayed)
    }

    @Test("Folge in der Schwelle (59:00 von 60:00, Schwelle 60 s): gehoert markieren")
    func episodeWithinTheTail() {
        let entry = [3_540, Self.now, Self.duration]
        // The precondition, assured: the row SHOWS this episode as played.
        #expect(ProgressMark.state(stored: entry, currentDuration: Self.duration, tail: Self.tail) == .played,
                "the row must show the episode as played")
        #expect(Self.episodeGesture(entry: entry) == .markPlayed,
                "within the tail the toggle offers unplayed and writes 0")
    }

    @Test("Folge am echten Ende und mit Marke ohne Dauer: ungehoert markieren")
    func episodeAtTheTrueEnd() {
        #expect(Self.episodeGesture(entry: [Self.duration, Self.now, Self.duration]) == .markUnplayed)
        #expect(Self.episodeGesture(entry: [ProgressMark.playedSentinel, Self.now]) == .markUnplayed)
    }

    @Test("Folge unberuehrt: gehoert markieren")
    func episodeUntouched() {
        #expect(Self.episodeGesture(entry: nil) == .markPlayed)
    }

    @Test("Folge in der Schwelle: die Frage schreibt nichts")
    func askingWritesNothing() {
        let id = "rss:mark-gesture-read:\(UUID().uuidString)"
        defer { ListeningStore.clearBackup(id) }
        let entry = [3_540, Self.now, Self.duration]
        ListeningStore.store(id, entry: entry)
        _ = podcastMarkGesture(Self.episode(id))
        #expect(ListeningStore.backup(id) == entry, "asking wrote something")
    }

    // MARK: - Server episodes (the flag the server holds)

    @Test("Server-Folge: Flag gesetzt ist das echte Ende, Bruchteil in der Schwelle nicht")
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

    @Test("Server-Buch vor der Schwelle, in der Schwelle, am echten Ende, mit Flag")
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

    @Test("Katalog-Buch: Flag ist das echte Ende, die Schwelle steht daneben")
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
    /// Comment lines do not count.
    static func labelSites(in text: String) -> (asked: Int, unasked: Int) {
        var asked = 0, unasked = 0
        for line in text.components(separatedBy: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), unmarkLabels.contains(where: code.contains) else { continue }
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

    @Test("der Zaehler sieht alte und neue Form")
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
    }

    @Test("jede Umschalt-Geste in einer Ansicht fragt die Regel")
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
