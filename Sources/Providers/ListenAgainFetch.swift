// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The start page's one network wait for "Listen Again". Started music the
/// session has not met yet (a cold start, a device that never opened the
/// playlist) is fetched so it can stand in the row. The page never waits
/// longer than the surface budget, at most `cap` ids are asked per pass, an
/// id already on its way is not asked twice, and an id whose fetch failed
/// waits the `FetchHoldback` time: a failure is no knowledge. An answer that
/// comes after the budget publishes itself into the row (`onLate`), so the
/// playlist appears without a further occasion.
@MainActor
final class ListenAgainFetch {
    static let shared = ListenAgainFetch()

    /// Ids fetched per pass at most; the rest waits for the next pass.
    static let cap = 6

    private let now: () -> Date
    /// When an id's fetch last failed.
    private(set) var failedAt: [String: Date] = [:]
    /// Ids whose fetch is on its way.
    private(set) var inFlight: Set<String> = []

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// Which of the unresolved ids this pass fetches.
    func plan(_ unresolved: [String]) -> [String] {
        let at = now()
        let askable = unresolved.filter {
            !inFlight.contains($0) && FetchHoldback.mayAsk(failedAt: failedAt[$0], now: at)
        }
        return Array(askable.prefix(Self.cap))
    }

    /// Fetches the planned ids one after another, waiting at most the
    /// surface budget. `one` answers whether an id resolves afterwards;
    /// `onLate` gets the ids that resolved after the budget ran out.
    func fetch(_ ids: [String], label: StaticString = #function,
               budget: Double = SourceBudget.seconds,
               onLate: @escaping @Sendable ([String]) async -> Void,
               _ one: @escaping @Sendable (String) async -> Bool) async {
        guard !ids.isEmpty else { return }
        inFlight.formUnion(ids)
        _ = await SourceBudget.value(default: [String](), label: label, budget: budget, onLate: onLate) { [weak self] in
            var resolved: [String] = []
            for id in ids {
                let answered = await one(id)
                await self?.finish(id, resolved: answered)
                if answered { resolved.append(id) }
            }
            return resolved
        }
    }

    private func finish(_ id: String, resolved: Bool) {
        inFlight.remove(id)
        failedAt[id] = resolved ? nil : now()
    }

    // MARK: - The start page's pass

    /// The ids the start page fetches in this pass.
    static func planPass(_ unresolved: [String]) -> [String] {
        shared.plan(unresolved)
    }

    /// Fetches for the start page; what resolves after the budget joins the
    /// "Listen Again" row through the late store, as the row's other late
    /// values do.
    static func fetchPass(_ ids: [String],
                          resolve: @escaping @MainActor @Sendable (String) -> LibraryItem?,
                          _ one: @escaping @Sendable (String) async -> Bool) async {
        await shared.fetch(ids, label: "listenAgain fetch", onLate: { late in
            await MainActor.run { LateMusicValues.shared.addRecentAlbums(late.compactMap(resolve)) }
        }, one)
    }
}
