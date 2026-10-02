// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The start page's one network wait for "Listen Again". Started music the
/// session has not met yet (a cold start, a device that never opened the
/// playlist) is fetched so it can stand in the row, but the page never
/// waits longer than the surface budget for it, fetches at most `cap` ids
/// per pass, and does not ask again for an id whose fetch failed in this
/// session. A late answer fills the provider's item cache and shows in the
/// next pass.
@MainActor
enum ListenAgainFetch {
    /// Ids fetched per pass at most; the rest waits for the next pass.
    static let cap = 6
    /// Ids whose fetch failed in this session. Not persisted: a server that
    /// was down is asked again after the next launch.
    private(set) static var failed: Set<String> = []

    /// Which of the unresolved ids this pass fetches.
    nonisolated static func plan(_ unresolved: [String], failed: Set<String>, cap: Int) -> [String] {
        Array(unresolved.filter { !failed.contains($0) }.prefix(cap))
    }

    /// Fetches the planned ids one after another, waiting at most the
    /// surface budget; `one` answers whether the id resolves afterwards.
    static func fetch(_ ids: [String], label: StaticString = #function,
                      _ one: @escaping @Sendable (String) async -> Bool) async {
        guard !ids.isEmpty else { return }
        await SourceBudget.run(label: label) {
            for id in ids {
                let resolved = await one(id)
                if !resolved { await MainActor.run { _ = ListenAgainFetch.failed.insert(id) } }
            }
        }
    }
}
