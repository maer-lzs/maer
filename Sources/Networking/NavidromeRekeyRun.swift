// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// This device's own stores move to Navidrome's new ids, once per server
/// address, after the server set up here reported itself as Navidrome 0.64
/// or later. Until then, and in between, the door (`SubsonicProvider.serverId`)
/// carries every stored id to the server; this pass moves the ids that are
/// compared as KEYS (a stand, a queue entry, a count), which the door cannot.
///
/// Each store rewrites through its own keeper, never behind it: the stores
/// hold their rows in memory and write their difference, so a rewrite of
/// the table alone would be undone by their next save.
@MainActor
enum NavidromeRekeyRun {
    /// What one store's step did.
    enum Outcome: Equatable {
        /// Its work is done: how many entries changed, how many it looked at.
        case done(changed: Int, total: Int)
        /// Not now: the pass is not done and runs again.
        case notNow
        /// Not possible here, for good: skipped with its reason, and the
        /// pass may still be done (a waiting pass would run for ever).
        case notHere(reason: String)
    }

    /// One store: its name for the log line, and its work.
    struct Step {
        let name: String
        let run: @MainActor (_ map: @escaping (String) -> String) async -> Outcome
        /// Whether the store's start missed rows (rows that did not decode
        /// in this build). The move runs over them and does not wait: they
        /// keep their old ids, and the line of the step says so.
        let missedRows: @MainActor () -> Bool

        init(name: String, missedRows: @escaping @MainActor () -> Bool = { false },
             outcome: @escaping @MainActor (_ map: @escaping (String) -> String) async -> Outcome) {
            self.name = name
            self.run = outcome
            self.missedRows = missedRows
        }

        /// A step whose work answers nil when it cannot be done now.
        init(name: String, missedRows: @escaping @MainActor () -> Bool = { false },
             _ work: @escaping @MainActor (_ map: @escaping (String) -> String) async -> (changed: Int, total: Int)?) {
            self.name = name
            self.run = { map in
                guard let result = await work(map) else { return .notNow }
                return .done(changed: result.changed, total: result.total)
            }
            self.missedRows = missedRows
        }
    }

    /// The line of a step that did its work. Rows its start could not read
    /// are named: they keep their old ids, and the pass does not wait for
    /// them, because they do not decode in this build at any later start.
    nonisolated static func doneLine(_ name: String, changed: Int, total: Int, missedRows: Bool, by caller: String) -> String {
        "REKEY \(name) rewritten=\(changed) unchanged=\(total - changed) by=\(caller)"
            + (missedRows ? "; rows not read at start keep their old ids" : "")
    }

    private static var running = false

    /// The stores of this device that keep item ids as keys. Some of them
    /// travel; how a carrier reads an old key from another device is the
    /// carrier's own rule.
    static var appSteps: [Step] {
        [
            // First: the kept song list is the one store the server answers
            // with error 70 while it holds old ids, and nothing else waits
            // on it.
            SubsonicProvider.songListRekeyStep,
            // Every store answers nil while its start could not read its
            // rows: they may hold old ids its memory lacks, and a marker set
            // over them would leave them under the old id for good.
            Step(name: "queue", missedRows: { PlayQueue.shared.startIncomplete }) { map in
                let queue = PlayQueue.shared
                let total = queue.ids.count
                return queue.rekey(map).map { ($0, total) }
            },
            Step(name: "context", missedRows: { PlaybackContext.shared.startIncomplete }) { map in
                let context = PlaybackContext.shared
                let total = context.ids.count
                return context.rekey(map).map { ($0, total) }
            },
            Step(name: "stands", missedRows: { ListeningStore.startMissedRows() }) { map in ListeningStore.rekey(map) },
            Step(name: "stats", missedRows: { ListeningStatsStore.shared.startMissedRows }) { await ListeningStatsStore.shared.rekeyItems($0) },
            Step(name: "pending", missedRows: { SyncQueue.shared.startIncomplete }) { map in
                let queue = SyncQueue.shared
                let total = queue.allPending().count
                return await queue.rekey(map).map { ($0, total) }
            },
            // These two also run in every reconcile of their carrier; here
            // for a device whose sync is off.
            Step(name: "choices") { map in UserChoiceCloudSync.shared.rekeyLocalChoices(map) },
            Step(name: "playlists", missedRows: { MaerPlaylists.shared.startIncomplete }) { MaerPlaylists.shared.rekey($0) },
            downloadsStep(),
        ]
    }

    /// The downloads' step. A moved download's persistent cover follows it
    /// at once, by both addresses, which need the music client. Without it
    /// (music off here) a download that would move keeps the pass open: the
    /// marker stays off, so the cover sweep holds (`isPending`), and the pass
    /// runs again once the covers can follow.
    ///
    /// A rename only queues its move in the disk chain. The step returns
    /// after every queued move landed (`settle`): the marker comes after it,
    /// and with the marker the sweep knows every cover by its new name and
    /// may demote the old one. While the step waits the pass is pending, so
    /// a sweep in between demotes nothing.
    static func downloadsStep(manager: @escaping @MainActor () -> DownloadManager = { DownloadManager.shared },
                              canRename: @escaping @MainActor () -> Bool = { SubsonicProvider.canRenameCovers },
                              rename: @escaping @MainActor (String, String) -> Void = SubsonicProvider.renameCover,
                              settle: @escaping @MainActor () async -> Void = { await Artwork.settleDisk() }) -> Step {
        Step(name: "downloads", missedRows: { manager().startIncomplete }) { map in
            let downloads = manager()
            await downloads.ensureScanned()
            guard canRename() || !downloads.wouldMove(map) else { return nil }
            let result = downloads.rekey(map, onMove: rename)
            await settle()
            return result
        }
    }

    /// Whether the pass is due and has not completed: the rule holds for the
    /// server set up here and its marker is missing. Until then the stores
    /// still hold the old ids, so a question about them by the new form has
    /// no complete answer (the cover sweep holds on it).
    static func isPending(server: String? = SubsonicProvider.configuredServerKey,
                          applies: Bool = SubsonicProvider.idsAreCanonical,
                          defaults: UserDefaults = .standard) -> Bool {
        guard applies, let server else { return false }
        return !defaults.bool(forKey: NavidromeRekey.markerKey(server: server))
    }

    /// Runs the pass when it is due (`isPending`). The marker comes after
    /// the last store, so a pass broken off runs again and finds the stores
    /// it already moved unchanged. Returns whether a pass ran.
    @discardableResult
    static func runIfDue(by caller: String,
                         server: String? = SubsonicProvider.configuredServerKey,
                         applies: Bool = SubsonicProvider.idsAreCanonical,
                         defaults: UserDefaults = .standard,
                         steps: [Step]? = nil) async -> Bool {
        guard isPending(server: server, applies: applies, defaults: defaults),
              let server, !running else { return false }
        let marker = NavidromeRekey.markerKey(server: server)
        running = true
        defer { running = false }
        let map: (String) -> String = { SubsonicProvider.canonicalItemId($0, canonical: true) }
        var complete = true
        for step in steps ?? appSteps {
            switch await step.run(map) {
            case .done(let changed, let total):
                let line = doneLine(step.name, changed: changed, total: total, missedRows: step.missedRows(), by: caller)
                Logger.library.notice("\(line, privacy: .public)")
            case .notNow:
                complete = false
                Logger.library.notice("REKEY \(step.name, privacy: .public) not possible now by=\(caller, privacy: .public); the pass runs again")
            case .notHere(let reason):
                Logger.library.notice("REKEY \(step.name, privacy: .public) skipped, not possible here reason=\(reason, privacy: .public) by=\(caller, privacy: .public)")
            }
        }
        // The marker only after a whole pass: a step that could not do its
        // work leaves it unset, and the next occasion runs the pass again;
        // the steps that did their work find their stores unchanged.
        guard complete else { return true }
        defaults.set(true, forKey: marker)
        Logger.library.notice("REKEY done by=\(caller, privacy: .public)")
        return true
    }
}
