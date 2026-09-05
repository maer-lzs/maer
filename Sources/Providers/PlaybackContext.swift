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

    /// The seam to disk: the document's directory and its name.
    private let ablage: Ablage
    private let documentName: String
    private let persists: Bool

    /// One versioned blob, so the file cannot become a migration trap.
    private nonisolated struct Stored: Codable, Sendable {
        var version: Int
        var sourceTitle: String?
        var ids: [String]
    }

    init(fileURL: URL, persists: Bool = false) {
        self.ablage = Ablage(directory: fileURL.deletingLastPathComponent())
        self.documentName = fileURL.lastPathComponent
        self.persists = persists
        if let decoded = ablage.loadNow(Stored.self, name: documentName).value {
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

    /// Each write waits for the one before it, so the last state lands last.
    private var pendingWrite: Task<Void, Never>?

    private func save() {
        guard persists else { return }
        let stored = Stored(version: 1, sourceTitle: sourceTitle, ids: ids)
        let ablage = ablage, name = documentName, empty = ids.isEmpty
        let previous = pendingWrite
        pendingWrite = Task(priority: .utility) {
            await previous?.value
            // A failure is logged by the seam; a context is rebuilt by the
            // next collection start, so nothing else is owed here.
            try? await ablage.save(stored, name: name, isEmpty: empty)   // tragbar, weil die Naht den Fehlschlag loggt
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
    enum Origin: Equatable { case order, context, binge, series }

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

    /// The WHOLE cascade including stage 3, as one rule: orders, context,
    /// then the medium's own continuation (podcasts binge and never fall
    /// through to series; books ask the series only with the setting on).
    /// The jump at a title's end and the what-plays-next line both call
    /// THIS, so what the line names is what actually plays; an empty
    /// answer means nothing plays, never an invented continuation.
    static func resolveNext(after finishedId: String,
                            queueIds: [String], contextIds: [String],
                            isPlayable: (String) -> Bool,
                            resolves: (String) -> Bool,
                            isPodcast: (String) -> Bool,
                            bingeNext: (String) -> String?,
                            seriesEnabled: Bool,
                            seriesNext: (String) -> String?) -> (id: String, origin: Origin)? {
        if let hit = next(queueIds: queueIds, contextIds: contextIds,
                          isPlayable: isPlayable, resolves: resolves) {
            return hit
        }
        if isPodcast(finishedId) {
            return bingeNext(finishedId).map { ($0, .binge) }
        }
        guard seriesEnabled else { return nil }
        return seriesNext(finishedId).map { ($0, .series) }
    }
}
