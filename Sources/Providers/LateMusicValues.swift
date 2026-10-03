// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine

/// The music sources of the start page, STORE-BACKED, which fits what is
/// already there (the catalogs work exactly this way).
///
/// Why it exists: these three were direct values inside `compute()`. A
/// result arriving after the source budget was dropped, and nothing
/// triggered a recompute. The row stayed empty until a tab switch. A view's
/// `@State` cannot be written from a late callback either. Held here, a late
/// value simply publishes, and the row fills up by itself.
///
/// One truth: `compute()` writes the punctual values here too, the view only
/// reads. No second copy in the view's state.
@MainActor
final class LateMusicValues: ObservableObject {
    static let shared = LateMusicValues()
    private init() {}

    /// Recently PLAYED albums (the "Recently Played" row).
    @Published private(set) var recentAlbums: [LibraryItem] = []
    /// Recently ADDED albums (mixed with books in "Recently Added").
    @Published private(set) var newAlbums: [LibraryItem] = []
    /// Album progress. Carries the Continue boundary of the mixed row.
    @Published private(set) var progress: [String: BookProgress] = [:]

    /// Apply through the shared calm gate: a landing value never reshapes a
    /// surface mid-scroll (same rule as every other late arrival).
    func setRecentAlbums(_ value: [LibraryItem]) {
        updateRecentAlbums { _ in value }
    }

    /// Started music that resolved only after the surface stopped waiting
    /// joins the row it belongs to, once.
    func addRecentAlbums(_ value: [LibraryItem]) {
        updateRecentAlbums { current in
            let known = Set(current.map(\.id))
            return current + value.filter { !known.contains($0.id) }
        }
    }

    /// One gate for both: the change reads the row as it stands when the
    /// gate opens, so a late addition never undoes a pass that landed first.
    private func updateRecentAlbums(_ change: @escaping @MainActor ([LibraryItem]) -> [LibraryItem]) {
        ScrollCalm.run { [weak self] in
            guard let self else { return }
            self.recentAlbums = change(self.recentAlbums)
        }
    }

    func setNewAlbums(_ value: [LibraryItem]) {
        ScrollCalm.run { [weak self] in self?.newAlbums = value }
    }

    func setProgress(_ value: [String: BookProgress]) {
        ScrollCalm.run { [weak self] in self?.progress = value }
    }
}
