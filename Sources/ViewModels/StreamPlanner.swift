// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Asks how the streams of a title's tracks are asked, for a server with
/// headers (`ServerHeaders.stream`) and for a source that attaches a
/// sign-in (`SignInStream.plan`): the track a start begins with before the
/// start, and then only the tracks playback will need soon (`window`), at
/// most `limit` at a time and in the order they are handed in. Each plan is
/// kept for the title: every load of a title makes a planner of its own.
@MainActor
final class StreamPlanner {
    typealias Ask = @Sendable (URL) async -> ServerHeaders.Stream

    private let ask: Ask
    let limit: Int
    private(set) var plans: [URL: ServerHeaders.Stream] = [:]
    /// The asks on their way, one per address: a plan wanted while its
    /// address is asked waits for that ask, from a jump, a start or a
    /// window alike.
    private var asking: [URL: Task<ServerHeaders.Stream, Never>] = [:]
    /// The waits of the windows for their plans, each until it is done.
    private var ahead: [UUID: Task<Void, Never>] = [:]
    /// How many asks run now, and the asks waiting for their turn, first
    /// in first out.
    private var running = 0
    private var turns: [(url: URL, go: CheckedContinuation<Void, Never>)] = []
    /// Set by `stop()`: nothing is asked or kept after it.
    private var stopped = false

    /// How many tracks after the one playing are asked ahead: enough that
    /// the switch to the next track does not wait for its plan.
    nonisolated static let tracksAhead = 2

    /// The tracks to plan while the track at `index` plays: that one and the
    /// next `tracksAhead`, never past the last. A start of a title of many
    /// files asks a few of them, not all; the others are asked as playback
    /// nears them.
    nonisolated static func window(from index: Int, count: Int) -> [Int] {
        guard index >= 0, index < count else { return [] }
        return Array(index...min(count - 1, index + tracksAhead))
    }

    init(limit: Int = 4, ask: @escaping Ask) {
        self.limit = limit
        self.ask = ask
    }

    /// The plan of one address: held, or the ask on its way, or asked now.
    /// A plan wanted now (a start, a jump, a rebuild) never waits behind
    /// the asks ahead: its ask starts at once, also one of this address
    /// that still waits for its turn.
    func plan(_ url: URL) async -> ServerHeaders.Stream {
        if let held = plans[url] { return held }
        return await asked(url, now: true).value
    }

    /// The one ask of an address, started when none is on its way. An ask
    /// ahead waits for its turn (at most `limit` run at once, in the order
    /// they were started); an ask wanted now takes one at once. It keeps
    /// its plan unless the planner stopped meanwhile.
    private func asked(_ url: URL, now: Bool) -> Task<ServerHeaders.Stream, Never> {
        if let running = asking[url] {
            if now { startAtOnce(url) }
            return running
        }
        let ask = self.ask
        let task = Task { [weak self] () -> ServerHeaders.Stream in
            guard let self else { return .plain }
            await self.turn(for: url, now: now)
            defer { self.release() }
            guard !self.stopped else { return .plain }
            let plan = await ask(url)
            if !self.stopped { self.plans[url] = plan }
            self.asking[url] = nil
            return plan
        }
        asking[url] = task
        return task
    }

    private func turn(for url: URL, now: Bool) async {
        if now || running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { turns.append((url, $0)) }
    }

    /// An ask of this address that waits for its turn starts now, beside
    /// the ones running.
    private func startAtOnce(_ url: URL) {
        guard let index = turns.firstIndex(where: { $0.url == url }) else { return }
        let waiting = turns.remove(at: index)
        running += 1
        waiting.go.resume()
    }

    /// Hands the turn to the next ask waiting, or frees it.
    private func release() {
        if turns.isEmpty {
            running -= 1
        } else {
            turns.removeFirst().go.resume()
        }
    }

    /// The plan of one address, waited for at most `seconds`. A plan that
    /// has not landed by then is held as `.plain`, the stream at its own
    /// address, until the question that is still on its way answers and
    /// takes its place. For a start, which must not wait for a host that
    /// is connected and does not answer.
    func plan(_ url: URL, within seconds: Double) async -> ServerHeaders.Stream {
        if let held = plans[url] { return held }
        // The first of the two answers ends the wait; nothing waits for the
        // other, so a question that hangs holds nobody.
        let (answers, continuation) = AsyncStream<ServerHeaders.Stream?>.makeStream()
        Task { continuation.yield(await self.plan(url)) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            continuation.yield(nil)
        }
        var first = answers.makeAsyncIterator()
        let answer = await first.next() ?? nil
        continuation.finish()
        if let answer { return answer }
        if plans[url] == nil { plans[url] = .plain }
        return plans[url] ?? .plain
    }

    /// Lets the plan of one address go, so the next `plan` asks it anew: a
    /// stream built from it failed to load, and the end it names may have
    /// lapsed.
    func forget(_ url: URL) { plans[url] = nil }

    /// Asks the plans of these addresses ahead, at most `limit` at a time
    /// and in the order handed in; an address whose plan is held or on its
    /// way is not asked again, so two windows that overlap ask each track
    /// once. `landed` runs after each one is kept.
    func planAhead(_ urls: [URL], landed: @escaping @MainActor () -> Void) {
        guard !stopped else { return }
        let pending = urls.filter { plans[$0] == nil && asking[$0] == nil }
        guard !pending.isEmpty else { return }
        for url in pending {
            let task = asked(url, now: false)
            let id = UUID()
            ahead[id] = Task { [weak self] in
                _ = await task.value
                guard let self else { return }
                self.ahead[id] = nil
                guard !self.stopped, !Task.isCancelled else { return }
                landed()
            }
        }
    }

    /// Ends the asking ahead: an ask waiting for its turn asks nothing, an
    /// ask on its way keeps nothing, and no plan lands after it. The plans
    /// held stay with this planner, and the next title's planner starts
    /// without them.
    func stop() {
        stopped = true
        for task in ahead.values { task.cancel() }
        ahead = [:]
        for task in asking.values { task.cancel() }
        asking = [:]
        let waiting = turns
        turns = []
        for turn in waiting {
            running += 1
            turn.go.resume()
        }
    }
}
