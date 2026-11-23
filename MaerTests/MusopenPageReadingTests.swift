// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The reading of the Musopen page, at its run: every answer in turn, a
/// failure kept beside what was read, and "Try Again" reading on from
/// where it stood.
@MainActor
struct MusopenPageReadingTests {
    private typealias Cursor = MusopenCatalog.Cursor
    private func item(_ id: String) -> LibraryItem { LibraryItem(id: MusopenCatalog.prefix + id, media: nil, addedAt: nil) }

    /// Answers in order; records where each read started.
    private final class Script {
        var answers: [MusopenPageReading.Answer]
        var asked: [Cursor] = []
        init(_ answers: [MusopenPageReading.Answer]) { self.answers = answers }
        func fetch(_ from: Cursor) -> MusopenPageReading.Answer {
            asked.append(from)
            return answers.isEmpty ? (.failed(reason: "script ran out"), from) : answers.removeFirst()
        }
    }

    @Test("a failure in the middle keeps what was read, stays where it stood and shows a line below the rows")
    func failureInTheMiddle() async {
        let second = Cursor(category: 0, token: "b")
        let script = Script([(.loaded(items: [item("1"), item("2")], fetched: 2), second),
                             (.failed(reason: "offline"), second)])
        var shown = 0
        let state = await MusopenPageReading.readAll(MusopenPageReading(), fetch: { script.fetch($0) }, show: { _ in shown += 1 })
        #expect(state.items.map(\.id) == [item("1").id, item("2").id])
        #expect(state.failed)
        #expect(state.cursor == second)
        #expect(shown == 2, "the page shows what it has after every answer")
        #expect(state.showsFailedLine, "a failure below rows already read stays without a visible state")
    }

    @Test("Try Again reads on from where it stood, and the failure is gone")
    func tryAgainReadsOn() async {
        let second = Cursor(category: 0, token: "b")
        var failed = MusopenPageReading()
        failed.items = [item("1")]
        failed.cursor = second
        failed.failed = true
        let script = Script([(.loaded(items: [item("3")], fetched: 1), nil)])
        let state = await MusopenPageReading.readAll(failed, fetch: { script.fetch($0) }, show: { _ in })
        #expect(script.asked == [second], "Try Again never read")
        #expect(state.items.map(\.id) == [item("1").id, item("3").id])
        #expect(!state.failed)
        #expect(state.cursor == nil)
        #expect(!state.showsFailedLine)
    }

    @Test("a failure with nothing read is the page's own failed state, not a line")
    func failureWithNothingRead() async {
        let script = Script([(.failed(reason: "offline"), Cursor())])
        let state = await MusopenPageReading.readAll(MusopenPageReading(), fetch: { script.fetch($0) }, show: { _ in })
        #expect(state.failed && state.items.isEmpty)
        #expect(!state.showsFailedLine)
    }

    @Test("answers whose files all stay out are read past; a reader that does not move stops")
    func edges() async {
        let b = Cursor(category: 0, token: "b"), c = Cursor(category: 1, token: nil)
        let script = Script([(.loaded(items: [], fetched: 50), b), (.loaded(items: [item("9")], fetched: 50), c),
                             (.loaded(items: [], fetched: 0), c)])
        let state = await MusopenPageReading.readAll(MusopenPageReading(), fetch: { script.fetch($0) }, show: { _ in })
        #expect(state.items.map(\.id) == [item("9").id])
        #expect(state.cursor == c, "the reader stopped where it no longer moved")
        #expect(!state.failed)
    }

    @Test("the page reads through the one reading and shows the line with its retry", .needsTheSources)
    func thePageReadsThroughIt() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/MusopenViews.swift"), encoding: .utf8))
        #expect(page.contains("MusopenPageReading.readAll(reading, fetch: { await MusopenLoader.next(from: $0) })"))
        #expect(page.contains("if reading.showsFailedLine {"))
        #expect(page.contains("LoadFailedView(form: .line"))
    }
}
#endif
