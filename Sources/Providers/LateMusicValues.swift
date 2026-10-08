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
///
/// What landed stays until an answer replaces it (`LandedValue`): a pass
/// whose source failed or ran out of time hands in nil and keeps the row,
/// and a late answer of an older pass does not replace a newer one.
@MainActor
final class LateMusicValues: ObservableObject {
    static let shared = LateMusicValues()
    /// The app holds one; a witness builds its own.
    init() {}

    /// Recently PLAYED albums (the "Recently Played" row): the server's
    /// shelf, then the started albums and playlists it lacks. Two halves,
    /// so a late shelf never drops the started ones and the other way round.
    @Published private(set) var recentAlbums: [LibraryItem] = []
    /// Recently ADDED albums as last answered. The next pass whose fetch
    /// gives no answer takes these for "Recently Added".
    @Published private(set) var newAlbums: [LibraryItem] = []
    /// Album progress. Carries the Continue boundary of the mixed row.
    @Published private(set) var progress: [String: BookProgress] = [:]

    /// The server's shelf of recently played albums as last answered.
    private(set) var shelf: [LibraryItem] = []
    private var started: [LibraryItem] = []
    private var landedPass: [PartialKeyPath<LateMusicValues>: Int] = [:]
    private var passes = 0

    /// A new pass of the start page; its answers carry this number.
    func beginPass() -> Int {
        passes += 1
        return passes
    }

    /// One answer of a pass for one source; nil is no answer.
    func setShelf(_ value: [LibraryItem]?, pass: Int) { land(\.shelf, value, pass: pass) }
    func setNewAlbums(_ value: [LibraryItem]?, pass: Int) { land(\.newAlbums, value, pass: pass) }
    func setProgress(_ value: [String: BookProgress]?, pass: Int) { land(\.progress, value, pass: pass) }

    /// The started albums of a pass, resolved from the progress it holds.
    /// Always an answer (empty is "nothing started"), and it carries its pass
    /// like the other halves: an older pass that ends last does not set the
    /// row back to its older state.
    func setStartedAlbums(_ value: [LibraryItem], pass: Int) { land(\.started, value, pass: pass) }

    /// Started music that resolved only after the surface stopped waiting
    /// joins the row it belongs to, once. Without a pass on purpose: it only
    /// adds, and an album a newer pass already carries is not added twice;
    /// dropping the late answer of an older pass would lose an album that
    /// pass asked for until a later pass resolves it.
    func addRecentAlbums(_ value: [LibraryItem]) {
        apply { values in
            let known = Set(values.started.map(\.id))
            values.started += value.filter { !known.contains($0.id) }
        }
    }

    private func land<Value>(_ key: ReferenceWritableKeyPath<LateMusicValues, Value>, _ value: Value?, pass: Int) {
        apply { values in
            guard let value,
                  LandedValue.replaces(answered: true, pass: pass, landedPass: values.landedPass[key] ?? 0)
            else { return }
            values.landedPass[key] = pass
            values[keyPath: key] = value
        }
    }

    /// Through the shared calm gate: a landing value never reshapes a
    /// surface mid-scroll (same rule as every other late arrival), and the
    /// change reads the values as they stand when the gate opens.
    private func apply(_ change: @escaping @MainActor (LateMusicValues) -> Void) {
        ScrollCalm.run { [weak self] in
            guard let self else { return }
            change(self)
            self.recentAlbums = Self.merged(shelf: self.shelf, started: self.started)
        }
    }

    /// The row: the shelf, then the started albums it does not carry.
    nonisolated static func merged(shelf: [LibraryItem], started: [LibraryItem]) -> [LibraryItem] {
        let known = Set(shelf.map(\.id))
        return shelf + started.filter { !known.contains($0.id) }
    }
}
