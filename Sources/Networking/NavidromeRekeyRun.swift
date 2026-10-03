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
    /// One store: its name for the log line, and its work, which returns how
    /// many entries changed and how many it looked at, or nil when it could
    /// not do its work now (then the pass is not done and runs again).
    struct Step {
        let name: String
        let run: @MainActor (_ map: @escaping (String) -> String) async -> (changed: Int, total: Int)?
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
            Step(name: "queue") { map in
                let queue = PlayQueue.shared
                let total = queue.ids.count
                return (queue.rekey(map), total)
            },
            Step(name: "context") { map in
                let context = PlaybackContext.shared
                let total = context.ids.count
                return (context.rekey(map), total)
            },
            Step(name: "stands") { map in
                let keys = Array(ListeningStore.positions().keys)
                let moves = NavidromeRekey.moves(keys, map)
                for move in moves { ListeningStore.move(from: move.from, to: move.to) }
                return (moves.count, keys.count)
            },
            Step(name: "stats") { map in
                let stats = ListeningStatsStore.shared
                let total = stats.ownData.secondsPerItem.count
                return (stats.rekeyItems(map), total)
            },
            Step(name: "pending") { map in
                let queue = SyncQueue.shared
                let total = queue.allPending().count
                return (await queue.rekey(map), total)
            },
            // These two also run in every reconcile of their carrier; here
            // for a device whose sync is off.
            Step(name: "choices") { map in UserChoiceCloudSync.shared.rekeyLocalChoices(map) },
            Step(name: "playlists") { map in MaerPlaylists.shared.rekey(map) },
            Step(name: "downloads") { map in
                let downloads = DownloadManager.shared
                await downloads.ensureScanned()
                return downloads.rekey(map)
            },
        ]
    }

    /// Runs the pass when it is due: the rule holds for the server set up
    /// here and its marker is missing. The marker comes after the last
    /// store, so a pass broken off runs again and finds the stores it
    /// already moved unchanged. Returns whether a pass ran.
    @discardableResult
    static func runIfDue(by caller: String,
                         server: String? = SubsonicProvider.configuredServerKey,
                         applies: Bool = SubsonicProvider.idsAreCanonical,
                         defaults: UserDefaults = .standard,
                         steps: [Step]? = nil) async -> Bool {
        guard applies, let server, !running else { return false }
        let marker = NavidromeRekey.markerKey(server: server)
        guard !defaults.bool(forKey: marker) else { return false }
        running = true
        defer { running = false }
        let map: (String) -> String = { SubsonicProvider.canonicalItemId($0, canonical: true) }
        var complete = true
        for step in steps ?? appSteps {
            guard let result = await step.run(map) else {
                complete = false
                Logger.library.notice("REKEY \(step.name, privacy: .public) not possible now by=\(caller, privacy: .public); the pass runs again")
                continue
            }
            Logger.library.notice("REKEY \(step.name, privacy: .public) rewritten=\(result.changed) unchanged=\(result.total - result.changed) by=\(caller, privacy: .public)")
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
