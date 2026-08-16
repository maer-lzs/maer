// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine

/// Q3a: the music sources of the start page, STORE-BACKED — the second of
/// the two options the order offered, and the one that fits what is already
/// there (the catalogs work exactly this way).
///
/// Why it exists: these three were direct values inside `compute()`. A
/// result arriving after the source budget was dropped, and nothing
/// triggered a recompute — the row stayed empty until a tab switch. A view's
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
    /// Album progress — carries the Continue boundary of the mixed row.
    @Published private(set) var progress: [String: BookProgress] = [:]

    /// Apply through the shared calm gate: a landing value never reshapes a
    /// surface mid-scroll (same rule as every other late arrival).
    func setRecentAlbums(_ value: [LibraryItem]) {
        BottomBarState.shared.runWhenCalm { [weak self] in self?.recentAlbums = value }
    }

    func setNewAlbums(_ value: [LibraryItem]) {
        BottomBarState.shared.runWhenCalm { [weak self] in self?.newAlbums = value }
    }

    func setProgress(_ value: [String: BookProgress]) {
        BottomBarState.shared.runWhenCalm { [weak self] in self?.progress = value }
    }
}
