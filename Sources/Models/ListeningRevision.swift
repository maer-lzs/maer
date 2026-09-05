// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

// The publisher is a non-Sendable Combine type held nonisolated by a
// MainActor class; the pre-concurrency import is the sanctioned suppression.
@preconcurrency import Combine
import Foundation
import OSLog

/// The ONE seam between the stores that create listening entries and the
/// rows that show them. Every event that creates or moves an entry (a
/// local start, a pause, a takeover, a pot or subscription adoption, an
/// import, a finish) bumps the revision once; every row that shows
/// listening state hangs on it and recomputes on the next frame, without
/// a restart, a tab switch or a pull. The revision counts EVENTS, never
/// playback ticks.
@MainActor
final class ListeningRevision: ObservableObject {
    static let shared = ListeningRevision()

    // Explicit publisher: under the project's MainActor default the
    // synthesized ObservableObject conformance from a @Published property
    // does not resolve.
    nonisolated let objectWillChange = ObservableObjectPublisher()

    private(set) var value = 0

    /// One event, one bump. The reason is for the log only.
    func bump(_ reason: String) {
        value += 1
        objectWillChange.send()
        Logger.player.notice("REVISION bump n=\(self.value) reason=\(reason, privacy: .public)")
    }
}
