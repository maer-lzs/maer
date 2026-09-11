// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

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
        persists: true,
        database: MaerDatabase.shared
    )

    @Published private(set) var ids: [String] = []
    /// What the rest continues FROM ("Weiter aus …" names its source).
    @Published private(set) var sourceTitle: String?

    /// The context lives as ONE row (`context` in `playback_context`): it
    /// is one struct, replaced whole on every change. The document in
    /// Documents is read only when the row holds nothing, poured into it
    /// once and set aside.
    nonisolated static let rowKey = "context"
    /// One versioned struct, the row's payload as it was the document's.
    nonisolated struct Stored: Codable, Equatable, Sendable {
        var version: Int
        var sourceTitle: String?
        var ids: [String]
    }

    /// The seam to disk for the document of the builds before: its
    /// directory and its name.
    private let ablage: Ablage
    private let documentName: String
    /// `shared` persists to the row; test instances stay in memory and
    /// touch neither disk nor database.
    private let persists: Bool
    private let keeper: RowKeeper<Stored>?

    init(fileURL: URL, persists: Bool = false, database: MaerDatabase? = nil) {
        self.ablage = Ablage(directory: fileURL.deletingLastPathComponent())
        self.documentName = fileURL.lastPathComponent
        self.persists = persists
        self.keeper = persists ? database.map { RowKeeper(database: $0, table: .playbackContext, label: "CONTEXT") } : nil
        if persists { load() }
    }

    /// The row first; the document only when the row holds nothing, poured
    /// into it once. A failed row read falls back to the document that was
    /// set aside and migrates nothing.
    private func load() {
        guard let keeper else {
            Logger.library.error("CONTEXT start: persisting without a database, nothing loads")
            return
        }
        let start = keeper.startNow()
        // A cleared context is an empty row, not a missing one, so a
        // document beside it is never poured over it again.
        var loaded: Stored? = start.rows.map { $0[Self.rowKey] ?? Stored(version: 1, sourceTitle: nil, ids: []) }
        var document: URL?
        if loaded == nil {
            // Corrupt is kept aside by the seam and never buried; the row
            // then starts fresh.
            if let current = ablage.loadNow(Stored.self, name: documentName).value {
                loaded = current
                document = ablage.url(for: documentName)
            }
            if start.failed {
                loaded = loaded ?? ablage.loadNow(Stored.self, name: documentName + ".migrated").value
                document = nil
            }
        }
        ids = loaded?.ids ?? []
        sourceTitle = loaded?.sourceTitle
        Logger.library.notice("CONTEXT start: entries=\(self.ids.count) migrate=\(document != nil)")
        if let document, let loaded { keeper.pour([Self.rowKey: loaded], settingAside: [document]) }
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

    /// Waits for every queued write of the row (tests, teardown).
    func awaitPendingWrites() async {
        await keeper?.awaitPendingWrites()
    }

    /// The row gets the whole struct; the keeper writes the diff and logs a
    /// failure, the context lives on in memory and is rebuilt by the next
    /// collection start.
    private func save() {
        guard persists else { return }
        keeper?.write([Self.rowKey: Stored(version: 1, sourceTitle: sourceTitle, ids: ids)])
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
