// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Asks how the streams of a title's tracks are asked, for a server with
/// headers (`ServerHeaders.stream`) and for a source that attaches a
/// sign-in (`SignInStream.plan`): the track a start begins with before the
/// start, every other one after it, at most `limit` at a time and in the
/// order they are handed in. Each plan is kept for the title: every load
/// of a title makes a planner of its own.
@MainActor
final class StreamPlanner {
    typealias Ask = @Sendable (URL) async -> ServerHeaders.Stream

    private let ask: Ask
    let limit: Int
    private(set) var plans: [URL: ServerHeaders.Stream] = [:]
    private var rest: Task<Void, Never>?

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

    /// Lets the plan of one address go, so the next `plan` asks it anew: a
    /// stream built from it failed to load, and the end it names may have
    /// lapsed.
    func forget(_ url: URL) { plans[url] = nil }

    /// Asks the plans of these addresses after the start, at most `limit`
    /// at a time; `landed` runs after each one is kept.
    func planRest(_ urls: [URL], landed: @escaping @MainActor () -> Void) {
        rest?.cancel()
        let pending = urls.filter { plans[$0] == nil }
        guard !pending.isEmpty else { return }
        let ask = self.ask
        let limit = self.limit
        rest = Task { [weak self] in
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
                    self.plans[url] = plan
                    landed()
                    if let next = waiting.popFirst() { group.addTask { (next, await ask(next)) } }
                }
            }
        }
    }

    /// Ends the asking of the rest; the plans held stay with this planner,
    /// and the next title's planner starts without them.
    func stop() {
        rest?.cancel()
        rest = nil
    }
}
