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
    /// Addresses asked ahead whose plan has not landed: each is asked once.
    private var asking: Set<URL> = []
    /// The asks ahead on their way, each until its last plan landed.
    private var ahead: [UUID: Task<Void, Never>] = [:]

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

    /// The plan of one address, asked now when it is not held.
    func plan(_ url: URL) async -> ServerHeaders.Stream {
        if let held = plans[url] { return held }
        let asked = await ask(url)
        plans[url] = asked
        return asked
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

    /// Asks the plans of these addresses ahead, at most `limit` at a time;
    /// an address whose plan is held or on its way is not asked again, so
    /// two windows that overlap ask each track once. `landed` runs after
    /// each one is kept.
    func planAhead(_ urls: [URL], landed: @escaping @MainActor () -> Void) {
        let pending = urls.filter { plans[$0] == nil && !asking.contains($0) }
        guard !pending.isEmpty else { return }
        asking.formUnion(pending)
        let ask = self.ask
        let limit = self.limit
        let id = UUID()
        ahead[id] = Task { [weak self] in
            var waiting = ArraySlice(pending)
            await withTaskGroup(of: (URL, ServerHeaders.Stream).self) { group in
                for _ in 0..<limit {
                    guard let url = waiting.popFirst() else { break }
                    group.addTask { (url, await ask(url)) }
                }
                for await (url, plan) in group {
                    guard let self, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    self.asking.remove(url)
                    self.plans[url] = plan
                    landed()
                    if let next = waiting.popFirst() { group.addTask { (next, await ask(next)) } }
                }
            }
            self?.ahead[id] = nil
        }
    }

    /// Ends the asking ahead; the plans held stay with this planner, and the
    /// next title's planner starts without them.
    func stop() {
        for task in ahead.values { task.cancel() }
        ahead = [:]
        asking = []
    }
}
