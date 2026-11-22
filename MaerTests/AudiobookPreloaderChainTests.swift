// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The download while listening runs once at a time. It starts from the
/// app's start, a book started, a book finished and its switch, each in a
/// task of its own; a second run that began while the first still loads
/// waits for it, so it sees the first one's books in its space and in
/// what the automatism holds, and never writes over that list.
@MainActor
struct AudiobookPreloaderChainTests {
    /// A run held open until the witness lets it go.
    final class Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var open = false

        func pass() async {
            if open { return }
            await withCheckedContinuation { waiting = $0 }
        }

        func release() {
            open = true
            waiting?.resume()
            waiting = nil
        }
    }

    /// What the runs did, in order.
    final class Log {
        var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
    }

    /// Long enough for an unchained run to have begun, without a sleep.
    private func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    @Test("a run that begins while another still loads starts after it ends, never beside it")
    func oneRunAtATime() async {
        let gate = Gate()
        let log = Log()
        let first = Task { @MainActor in
            await AudiobookPreloader.chained {
                log.add("first begins")
                await gate.pass()
                log.add("first ends")
            }
        }
        await settle()
        #expect(log.lines == ["first begins"], "the first run did not begin: \(log.lines)")
        let second = Task { @MainActor in
            await AudiobookPreloader.chained {
                log.add("second begins")
                log.add("second ends")
            }
        }
        await settle()
        #expect(log.lines == ["first begins"], "the second run began beside the first: \(log.lines)")
        gate.release()
        await first.value
        await second.value
        #expect(log.lines == ["first begins", "first ends", "second begins", "second ends"], "the runs crossed: \(log.lines)")
    }

    @Test("every entry of the download while listening goes through the one chain", .needsTheSources)
    func everyRunIsChained() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.path.hasSuffix("/Sources/Providers/AudiobookPreloader.swift") })
        let text = try SourceTree.text(file)
        let entry = try #require(text.range(of: "static func run("), "the entry is gone")
        let body = text[entry.upperBound...].prefix(600)
        #expect(body.contains("await chained {"), "the entry runs beside the chain")
    }
}
#endif
