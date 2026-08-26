// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The ONE place that asks WHY the key-value store changed.
///
/// The silent failure this project cannot afford: when the shared 1 MB is
/// exhausted, iCloud stops accepting writes and says so ONLY through this
/// reason code. No error at any call site. "Sync quietly stopped" then looks
/// exactly like "nothing changed", and two devices drift apart for weeks.
///
/// The check used to live inside the statistics sync, and that made its
/// coverage narrower than its purpose: that service bails out immediately when
/// the iCloud switch is off, while the three other cloud paths (podcast
/// progress, playlists, premium classification) observe the same notification
/// without ever looking at the reason. Exactly the case worth catching. The
/// channel fills up because `podcastProgress` fills it. Hung on a service
/// that has nothing to do with progress.
///
/// So the watch stands on its own and starts with the app, independent of any
/// single service and of every sync switch. A store nobody writes to still
/// reports a quota violation caused by someone else's writes.
@MainActor
final class CloudQuotaWatch {
    static let shared = CloudQuotaWatch()

    private let store: NSUbiquitousKeyValueStore
    private var didStart = false
    /// Test-visible: the guard must register exactly once, however often the
    /// app's start path runs.
    private(set) var observerRegistrations = 0

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        observerRegistrations += 1
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store)
    }

    /// Only the REASON crosses the actor boundary, not the notification: a
    /// `Notification` is not `Sendable`, and the code is all this needs.
    @objc private nonisolated func cloudChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        Task { @MainActor in Self.note(reason: reason) }
    }

    /// The rule itself. Pure enough to call from anywhere and to test without
    /// a store. Every observer of the change notification routes its reason
    /// through HERE; nobody re-implements the comparison.
    static func note(reason: Int?) {
        guard reason == NSUbiquitousKeyValueStoreQuotaViolationChange else { return }
        Logger.library.error("iCloud key-value quota exceeded — progress, playlists and stats stop syncing until space is freed")
        AppStorageKeys.noteCloudQuotaViolation()
    }

    /// Whether a reason code means "the channel is full". Named so a caller
    /// reads as a question, and so the test does not have to name Apple's
    /// constant twice.
    nonisolated static func isQuotaViolation(_ reason: Int?) -> Bool {
        reason == NSUbiquitousKeyValueStoreQuotaViolationChange
    }
}
