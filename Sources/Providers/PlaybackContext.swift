// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine

/// The CONTEXT rest of a collection start (shuffle, album, playlist, "play
/// all") — deliberately NOT the queue. The one queue used to hold two
/// things with opposite lifetimes: the user's ORDERS (survive everything)
/// and this rest (dies with the next start). A shuffle start therefore
/// threw the hand-placed orders away, and hours-old music won against the
/// next episode. Now: orders are `PlayQueue`, the rest lives here.
///
/// Lifetime rules (the decided invariants):
/// - a new user start REPLACES the context (collection start) or CLEARS it
///   (single-item start); never the orders;
/// - what starts or finishes leaves the context, like the queue;
/// - it survives an app restart WITH the running title (whoever leaves an
///   album overnight expects its rest in the morning).
@MainActor
final class PlaybackContext: ObservableObject {
    static let shared = PlaybackContext(
        fileURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playback_context.json"),
        persists: true
    )

    @Published private(set) var ids: [String] = []
    /// What the rest continues FROM ("Weiter aus …" names its source).
    @Published private(set) var sourceTitle: String?

    private let fileURL: URL
    private let persists: Bool

    /// One versioned blob, so the file cannot become a migration trap.
    private struct Stored: Codable {
        var version: Int
        var sourceTitle: String?
        var ids: [String]
    }

    init(fileURL: URL, persists: Bool = false) {
        self.fileURL = fileURL
        self.persists = persists
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            ids = decoded.ids
            sourceTitle = decoded.sourceTitle
        }
    }

    var isEmpty: Bool { ids.isEmpty }

    /// A collection start hands over its rest. Radio never queues anywhere
    /// (play only replaces the active playback), same rule as the queue.
    func replace(ids newIds: [String], source: String?) {
        ids = newIds.filter { PlayQueue.canEnqueue($0) }
        sourceTitle = ids.isEmpty ? nil : source
        save()
    }

    /// A single-item user start: the old context dies, nothing replaces it
    /// (the medium's own continuation is cascade step 3, not a context).
    func clear() {
        guard !ids.isEmpty || sourceTitle != nil else { return }
        ids = []
        sourceTitle = nil
        save()
    }

    /// Started or finished flies out: the context never re-offers what
    /// already ran.
    func remove(_ id: String) {
        guard ids.contains(id) else { return }
        ids.removeAll { $0 == id }
        if ids.isEmpty { sourceTitle = nil }
        save()
    }

    private func save() {
        guard persists else { return }
        let stored = Stored(version: 1, sourceTitle: sourceTitle, ids: ids)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// The pure advance rule at a title's end: ORDERS first (cross-media, the
/// explicitly built evening plan), then the CONTEXT of what was running,
/// then the caller falls back to the medium's own continuation (binge,
/// next-in-series). One rule for the jump AND for the "what plays next"
/// line, because a second derivation could diverge, and what the line names must
/// be what actually plays.
nonisolated enum PlaybackAdvance {
    enum Origin: Equatable { case order, context }

    static func next(queueIds: [String], contextIds: [String],
                     isPlayable: (String) -> Bool,
                     resolves: (String) -> Bool) -> (id: String, origin: Origin)? {
        if let id = QueueContinuation.nextPlayable(ids: queueIds,
                                                  isPlayable: isPlayable,
                                                  resolves: resolves) {
            return (id, .order)
        }
        if let id = QueueContinuation.nextPlayable(ids: contextIds,
                                                  isPlayable: isPlayable,
                                                  resolves: resolves) {
            return (id, .context)
        }
        return nil
    }
}
