// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Syncs podcast progress (`localPosition`) across your own Apple devices via
/// iCloud. So "continue on the iPad" works without an ABS server too (and in
/// addition to it).
///
/// The runner of the pot: it reads every stand the carrier holds, merges
/// against the device's own, and writes what moved. The transport is a
/// `StandCarrier`; the key-value store is the first (one consolidated key
/// for every pot item), CloudKit the next.
///
/// Merge rule: per episode the newer `updatedAtMs` wins; the winner is written
/// back to the stale side (local OR iCloud). No ping-pong, because writes only
/// happen on a real timestamp lag.
///
/// Without the iCloud switch the runner stays silent. Then everything runs
/// purely locally as before (no crash, no data loss).
@MainActor
final class PodcastCloudSync {
    static let shared = AccessFollowers.enrolled(PodcastCloudSync(
        identity: { AccessFollowers.identity },
        shelf: MaerDatabase.restingShelf))

    private var carrier: any StandCarrier
    private var generation = CarrierGeneration()
    /// The stock this runner reads and writes; a witness hands in its own.
    private let defaults: UserDefaults
    /// The account signed in now (`AccessFollowers.identity`), nil when none
    /// is, and where the stands of another account rest. Only the app's
    /// runner has them; every other one keeps no owner and never touches a
    /// shelf.
    private let identity: () -> String?
    /// The family's way through the shelf (`ShelfFollower`); nil without one.
    private let follower: ShelfFollower?

    /// Whether the rows of the stands carry the mark of a replacement
    /// (`OwnerMark`); the app's rows by default, a witness hands in its own.
    private let standsMarked: (_ replacement: String) throws -> Bool

    init(carrier: any StandCarrier = StandCarriers.make(),
         defaults: UserDefaults = .standard,
         identity: @escaping () -> String? = { nil },
         shelf: RestingShelf? = nil,
         standsMarked: @escaping (_ replacement: String) throws -> Bool = {
             try OwnerMark.stands(family: PodcastCloudSync.shelfFamily, replacement: $0, database: .shared)
         }) {
        self.carrier = carrier
        self.defaults = defaults
        self.identity = identity
        self.standsMarked = standsMarked
        self.follower = shelf.map { ShelfFollower(family: Self.shelfFamily, shelf: $0, label: "STAND") }
    }

    static let shelfFamily = "stands"

    /// The progress store re-reads the stock this runner changed.
    private func reloadProgress() { PodcastProgressStore.shared.reload() }

    /// Whether the stands belong to the account signed in now, handing the
    /// travelling part over first by the shelf's one rule
    /// (`RestingShelf.handOver`). False while it cannot (the stock not read
    /// whole, a rest not laid or unreadable); nothing then is merged, taken
    /// in or sent, since a round would carry the holder's stands to the
    /// account and the account's into the holder's stock.
    private func followsTheAccount(previous: String? = nil) -> Bool {
        guard let follower, let scope = identity() else { return true }
        let defaults = self.defaults
        guard let step = follower.follow(
            to: scope, previous: previous, unread: ListeningStore.readFailed(in: defaults), landing: .marked,
            landed: standsMarked,
            current: { ListeningStore.resting(where: Self.potCarries, in: defaults) },
            replace: { [weak follower] rest, _, name in
                let landed: @Sendable () -> Void = { Task { @MainActor in follower?.markLanded(name) } }
                ListeningStore.replaceForNewOwner(
                    with: rest, where: Self.potCarries, in: defaults,
                    replacement: .init(family: Self.shelfFamily, name: name, travels: Self.potCarries, landed: landed))
            }) else { return false }
        switch step {
        case .kept, .first: break
        case .unread:
            Logger.library.notice("STAND owner held: stock not read whole")
            return false
        case .moved:
            Logger.library.notice("STAND owner moved")
            reloadProgress()
        }
        return true
    }

    /// The feed keys of the subscribed shows, nil while the subscriptions
    /// are not loaded (an empty store at cold start would read every show
    /// as unsubscribed).
    private func subscribedShowKeys() -> Set<String>? {
        let subscriptions = PodcastSubscriptions.shared
        guard subscriptions.isLoaded else { return nil }
        return Set(subscriptions.shows.map { PodcastIdentity.feedKey($0.feedURL) })
    }

    /// Asks the carrier for the other side's changes now: the foreground
    /// and the poll while playing. What arrived comes in through the
    /// carrier's `onChange` as a receive-only pass; nothing is written.
    func pull(by caller: String) async {
        guard AppStorageKeys.syncAcrossDevicesEnabled else { return }
        await carrier.refresh(by: caller)
    }

    /// Whether the player's tick asks the carrier now: the cadence is the
    /// carrier's, the player only counts ticks.
    func pullDue(tick: Int) -> Bool {
        PlaybackClaimRules.due(tick: tick, everySeconds: carrier.pullSeconds)
    }

    /// The tick's pull, when the carrier's cadence says so.
    func pullIfDue(tick: Int, by caller: String) async {
        guard pullDue(tick: tick) else { return }
        await pull(by: caller)
    }

    /// How often the playing device sends its state to the pot; the
    /// carrier's number, asked rather than assumed.
    var sendCadenceSeconds: Double { carrier.sendCadenceSeconds }

    /// When the playing device last sent its state to the pot without a
    /// deliberate occasion. Held here and not in the player: the runner
    /// knows the carrier's cadence, the player only knows that it plays.
    private(set) var lastSendAtMs: Double = 0

    /// The playing device's state to the pot: at a deliberate occasion
    /// always, on the tick only when the carrier's cadence is due. The pot
    /// is no longer written as an answer to foreign changes, so this is
    /// the one sender while playing.
    func sendState(changedId id: String, deliberate: Bool, nowMs: Double = Date().timeIntervalSince1970 * 1000) {
        guard CloudSendRules.shouldSend(deliberate: deliberate, lastSentAtMs: lastSendAtMs, nowMs: nowMs,
                                        cadenceSeconds: carrier.sendCadenceSeconds) else { return }
        lastSendAtMs = nowMs
        reconcile(changedId: id)
    }
    /// The EXISTING progress channel now also carries the
    /// classes that have no server behind them. Catalog works and local
    /// sideloads keep their position in the very same `localPosition` store,
    /// and the user's goal for these rounds is "identical state on all
    /// devices". A second channel for the same question would be exactly the
    /// second version we are abolishing everywhere else.
    ///
    /// Server-owned ids (ABS books) stay out: they travel with the server
    /// sync, which owns their truth.
    ///
    /// **Edge, deliberately not filtered:** a `local:` sideload only exists
    /// on the device that holds the file. Its POSITION still travels. That
    /// is harmless and right: device B shows the book once the file is there,
    /// and then the position is already correct.
    /// The ONE answer to "does this item's stand live in the pot": feeds,
    /// server podcasts, sideloads and every catalogue prefix. The start
    /// pull before playback asks it too, so a catalogue book on the other
    /// device starts at the pot's stand and not at the mark of the last
    /// full reconcile. A new catalogue prefix inherits the way.
    nonisolated static let potItemPrefixes = ["rss:", "abspod:", "local:"] + FreeCatalog.allPrefixes

    nonisolated static func potCarries(_ itemId: String) -> Bool {
        potItemPrefixes.contains(where: { itemId.hasPrefix($0) })
    }

    /// Guard against double observer registration (start() can run again when
    /// the library view is recreated, e.g. logout→login). A second observer
    /// would double every reconcile on external iCloud changes.
    private var didStart = false
    /// How many times the observer was actually registered. Must never exceed
    /// 1 (exposed for tests).
    private(set) var observerRegistrations = 0

    /// Call once at app start: listen for iCloud changes + reconcile immediately.
    func start() {
        guard AppStorageKeys.syncAcrossDevicesEnabled else { return }
        guard !didStart else { reconcile(); return }
        didStart = true
        observerRegistrations += 1
        startCarrier(by: "start")
        reconcile()
    }

    private func startCarrier(by caller: String) {
        Logger.library.notice("STAND carrier=\(self.carrier.name, privacy: .public) by=\(caller, privacy: .public)")
        // A foreign change is taken in, never answered with a write:
        // while this device plays, its local position is always newer
        // than the pot, so answering every foreign change (the other
        // device's claim beats among them) wrote the whole pot back
        // each time, and that write was the next foreign change over
        // there. Sending has its own occasions.
        carrier.start(onChange: generation.guarded({ [weak self] in self?.generation }) { [weak self] in
            self?.reconcile(pushing: false)
        })
    }

    /// The carrier the access of this moment asks for, when it travels
    /// another way than the held one. A running runner starts it as at a
    /// cold start; the old carrier leaves the register of refreshers, and
    /// whatever it still delivers lands in an old generation.
    func follow(_ next: @autoclosure () -> any StandCarrier, signedIn: Bool, identityChanged: Bool = false, by caller: String) {
        guard CarrierWay.mustChange(holdsService: CarrierWay.isService(carrierName: carrier.name),
                                    signedIn: signedIn, identityChanged: identityChanged) else { return }
        carrier.stop()
        CarrierRefreshers.unregister(carrier)
        carrier = next()
        generation.advance()
        guard didStart else { return }
        startCarrier(by: caller)
        reconcile()
    }

    /// Merge local podcast positions and the iCloud blob (newest-wins) and bring
    /// both sides to the shared state.
    /// `pushing: false` takes the pot in and writes nothing back; the
    /// explicit callers (start, foreground, background, import, refresh)
    /// keep pushing.
    func reconcile(pushing: Bool = true, caller: String = #function) {
        guard AppStorageKeys.syncAcrossDevicesEnabled else { return }
        guard followsTheAccount() else {
            Logger.library.notice("STAND round held: the stands wait for their owner")
            return
        }

        // Collect local positions, from the store's stock.
        let local = ListeningStore.positions(in: defaults).filter { Self.potCarries($0.key) }
        let signpost = PerfSignpost.standMerge(entries: local.count)
        defer { signpost.end() }

        // What the carrier holds.
        var cloud = carrier.stands()

        // The travel-set cleanup (finished episodes of unsubscribed shows
        // leave the pot; the device and the history keep theirs). Only
        // with the subscriptions LOADED: an empty store at cold start
        // would read every show as unsubscribed and clear what it must not
        // (the loading-state class).
        var droppedCount = 0
        var removed: Set<String> = []
        // Only where room is the reason: the blob holds one megabyte for
        // everything, CloudKit holds a record per stand. In a roomy pot a
        // stand stays, because "unsubscribed here" is not "unsubscribed
        // anywhere".
        if carrier.hasRoomLimit, let keys = subscribedShowKeys() {
            let cleanedResult = Self.cleaned(cloud: cloud,
                                             isSubscribedShow: { keys.contains($0) })
            removed = Set(cloud.keys).subtracting(cleanedResult.kept.keys)
            cloud = cleanedResult.kept
            droppedCount = cleanedResult.droppedCount
        }

        let outcome = Self.merge(local: local, cloud: cloud)
        // Tombstones in mass clear their import marks together, one write
        // per list instead of one per episode.
        ForeignMarks.clearingTogether {
            for (id, value) in outcome.toLocal {
                // iCloud newer → local, through the stock's door: a position
                // written past it would escape the row copy and the rules
                // every other write path carries.
                ListeningStore.store(id, entry: value, in: defaults)
            }
        }
        // What no longer travels is not written back either; otherwise
        // the very next merge would undo the cleanup from the local side.
        var toCloud = outcome.toCloud
        if carrier.hasRoomLimit, let keys = subscribedShowKeys() {
            toCloud = toCloud.filter {
                Self.travels(id: $0.key, entry: $0.value,
                             isSubscribedShow: { keys.contains($0) })
            }
        }
        if pushing, !toCloud.isEmpty || droppedCount > 0 {
            // local newer → the carrier, the cleaned entries leave with it
            carrier.write(upserts: toCloud, removing: removed, by: caller)
            if droppedCount > 0 {
                Logger.library.notice("KVS cleanup: \(droppedCount) finished episodes of unsubscribed shows left the travel set")
            }
        }
        if !outcome.toLocal.isEmpty {
            // Have the UI/sections and ABS provider display re-evaluate.
            reloadProgress()
            // Personen-Ebene: reconciled transitions land in the listen log.
            PodcastListenLog.shared.noteReconciled(guids: outcome.toLocal.keys, before: local)
        }
        // Record only what MOVED: positions taken in, positions actually
        // pushed. A receive-only pass (every foreign claim beat while the
        // other device plays) always finds the local side "newer" and
        // would write a ring entry every ten seconds without a change; it
        // only notes the check. Single-key writes stay out as well.
        let moved = Self.ringCounters(down: outcome.toLocal.count,
                                      up: toCloud.count, pushing: pushing)
        SyncHistoryStore.shared.record(SyncHistory.entry(
            service: carrier.historyService, direction: .both,
            counters: [.init(key: .positionsDown, value: moved?.down ?? 0),
                       .init(key: .positionsUp, value: moved?.up ?? 0)],
            duration: 0,
            deviceId: SyncHistoryStore.entryDeviceId), moved: moved != nil)
        if let moved {
            Logger.library.notice("SYNC history icloud down=\(moved.down) up=\(moved.up) by=\(caller, privacy: .public)")
        } else {
            // A clean full-scan merge leaves no ring entry, only the stamp.
            Logger.library.debug("SYNC check icloud pushing=\(pushing) localNewer=\(toCloud.count) by=\(caller, privacy: .public)")
        }
    }

    /// What a full-scan merge writes into the ring: nil when nothing moved.
    /// Positions the local side holds newer count only when they were
    /// pushed; on a receive-only pass they are not a change.
    nonisolated static func ringCounters(down: Int, up: Int, pushing: Bool) -> (down: Int, up: Int)? {
        let pushed = pushing ? up : 0
        guard down > 0 || pushed > 0 else { return nil }
        return (down, pushed)
    }

    /// Travel membership is DERIVED, never a tombstone: an entry travels
    /// unless it is FINISHED and its show is UNSUBSCRIBED. Re-subscribing
    /// simply makes the condition false again, and the next reconcile
    /// carries the still-local position back into the travel set; nothing
    /// to migrate, nothing that could shadow a comeback.
    ///
    /// Only rss episodes have an unsubscribe concept; server shows
    /// (abspod), catalog works and sideloads always travel. "Finished" is
    /// the ONE derived rule (`ProgressMark.isPlayed`); without a stored
    /// duration or sentinel the doubt keeps the entry aboard. Membership is
    /// judged on the SHOW, never on episode presence in the feed: a rotated-
    /// out episode of a subscribed show must not read as unsubscribed.
    nonisolated static func travels(id: String, entry: [Double],
                                    isSubscribedShow: (String) -> Bool) -> Bool {
        guard ItemNamespace.isRSS(id) else { return true }
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[1].isEmpty else { return true }
        if isSubscribedShow(String(parts[1])) { return true }
        return !ProgressMark.reachedEnd(stored: entry, currentDuration: 0)
    }

    /// The cleanup over the CLOUD blob only. Local positions and the
    /// listen log are the device's own and are never touched here:
    /// positions leave the travel pot, never the device, never the history.
    nonisolated static func cleaned(cloud: [String: [Double]],
                                    isSubscribedShow: (String) -> Bool)
        -> (kept: [String: [Double]], droppedCount: Int) {
        var kept: [String: [Double]] = [:]
        var dropped = 0
        for (id, entry) in cloud {
            if travels(id: id, entry: entry, isSubscribedShow: isSubscribedShow) {
                kept[id] = entry
            } else {
                dropped += 1
            }
        }
        return (kept, dropped)
    }

    /// Pure newest-wins merge (testable): per id the newer `updatedAtMs` wins;
    /// equal timestamps produce NO write on either side (no ping-pong).
    nonisolated static func merge(local: [String: [Double]], cloud: [String: [Double]])
        -> (toLocal: [String: [Double]], toCloud: [String: [Double]]) {
        var toLocal: [String: [Double]] = [:]
        var toCloud: [String: [Double]] = [:]
        for id in Set(local.keys).union(cloud.keys) {
            let lts = ProgressMark.timestamp(local[id]) ?? -1
            let cts = ProgressMark.timestamp(cloud[id]) ?? -1
            // The winner brings position and timestamp; the marked duration
            // survives from EITHER side. A device on an older build writes
            // two-value marks with a fresh timestamp. Without this it would
            // wipe the reference point on every reconcile, silently.
            // The FORM travels exactly like the duration: the winner brings its
            // own if it has one, otherwise the other side's survives. Without
            // passing it the merge would rebuild the entry from the LOSING
            // side and the form would never leave this device. Measured, not
            // assumed (StartedFormAcrossDevicesTests).
            if cts > lts, let c = cloud[id] {
                toLocal[id] = ProgressMark.advancing(local[id], position: c[0],
                                                     duration: ProgressMark.markedDuration(c) ?? 0,
                                                     nowMs: c[1],
                                                     form: ProgressMark.markedForm(c))
            } else if lts > cts, let l = local[id] {
                toCloud[id] = ProgressMark.advancing(cloud[id], position: l[0],
                                                     duration: ProgressMark.markedDuration(l) ?? 0,
                                                     nowMs: l[1],
                                                     form: ProgressMark.markedForm(l))
            }
        }
        return (toLocal, toCloud)
    }

    /// Decision of the single-id merge (pure, testable). Matches `merge` for
    /// value-vs-value cases; the local-nil case deliberately differs from the
    /// full scan: a deleted local key means "mark unplayed", so instead of
    /// restoring the old cloud value a fresh zero tombstone is pushed.
    enum SingleMergeOutcome: Equatable {
        case adoptCloud([Double])
        case pushLocal([Double])
        case pushTombstone
        case none
    }

    nonisolated static func mergeSingle(local: [Double]?, cloud: [Double]?) -> SingleMergeOutcome {
        let lts = ProgressMark.timestamp(local) ?? -1
        let cts = ProgressMark.timestamp(cloud) ?? -1
        if cts > lts, let c = cloud {
            if local == nil { return .pushTombstone }
            return .adoptCloud(ProgressMark.advancing(local, position: c[0],
                                                      duration: ProgressMark.markedDuration(c) ?? 0,
                                                      nowMs: c[1],
                                                      form: ProgressMark.markedForm(c)))
        }
        if lts > cts, let l = local {
            return .pushLocal(ProgressMark.advancing(cloud, position: l[0],
                                                     duration: ProgressMark.markedDuration(l) ?? 0,
                                                     nowMs: l[1],
                                                     form: ProgressMark.markedForm(l)))
        }
        return .none
    }

    /// Targeted single-episode merge. For the frequent per-write callers
    /// (mark played/unplayed, position saves). The full `reconcile()` enumerates
    /// the ENTIRE UserDefaults per call, which is far too expensive to run per
    /// episode (mark-all on a 200-episode show = 200 full scans).
    /// `pushing: false` only adopts a newer cloud entry (the play start
    /// asks for the freshest stand and writes nothing: a play is not a
    /// change of state, and the stand travels in the claim). `caller`
    /// names the writer in the pot's log line.
    func reconcile(changedId id: String, pushing: Bool = true, caller: String = #function) {
        guard AppStorageKeys.syncAcrossDevicesEnabled else { return }
        guard Self.potCarries(id) else { return }
        guard followsTheAccount() else { return }
        let localArr = ListeningStore.backup(id, in: defaults)
        let cloudArr = carrier.stands()[id]
        switch Self.mergeSingle(local: localArr, cloud: cloudArr) {
        case .adoptCloud(let value):
            ListeningStore.store(id, entry: value, in: defaults)
            reloadProgress()
            PodcastListenLog.shared.noteReconciled(guids: [id], before: localArr.map { [id: $0] } ?? [:])
        case .pushLocal(let value):
            guard pushing else { break }
            // EVERY write path runs through the travel rule, or this one
            // would put a cleaned entry straight back into the pot and the
            // next full reconcile would remove it again (blob churn). With
            // the subscriptions not loaded the doubt travels, like before.
            if let keys = subscribedShowKeys() {
                guard Self.travels(id: id, entry: value,
                                   isSubscribedShow: { keys.contains($0) }) else { break }
            }
            carrier.write(upserts: [id: value], removing: [], by: caller)
        case .pushTombstone:
            // Local delete (mark unplayed) wins only with a fresh timestamp we
            // don't have. Write an explicit zero so other devices follow.
            // A receive-only pass never writes: the play start of an item
            // this device holds no stand for yet would otherwise wipe the
            // other device's stand with a zero (found by the carrier
            // witness, 06.09.).
            guard pushing else { break }
            carrier.write(upserts: [id: [0.0, Date().timeIntervalSince1970 * 1000]], removing: [], by: caller)
        case .none:
            break
        }
    }
}

extension PodcastCloudSync: AccessFollower {
    var followerName: String { "stands" }

    /// The stock follows a change of account at the moment of the change,
    /// with the sync switch off as well (`AccessFollower.followOwner`).
    func followOwner(previous: String?) {
        _ = followsTheAccount(previous: previous)
    }

    func followAccess(signedIn: Bool, identityChanged: Bool, by caller: String) {
        follow(StandCarriers.make(), signedIn: signedIn, identityChanged: identityChanged, by: caller)
    }
}

/// When the playing device SENDS its podcast state to the pot. Pure, so
/// the budget is testable: during playback without a change of phase the
/// pot is written at most once a minute. Measured before this rule: four
/// whole-pot writes of 325 KB in 25 seconds, one per foreign change, which
/// is the class the key-value store throttles.
nonisolated enum CloudSendRules {
    /// The cadence while playing, in seconds. The rest is events.
    static let cadenceSeconds: Double = 60

    /// A deliberate occasion (pause, stop, seek, a change of phase,
    /// import, adoption) always sends; the tick only when the cadence is
    /// due. The cadence is the carrier's (`StandCarrier.sendCadenceSeconds`).
    static func shouldSend(deliberate: Bool, lastSentAtMs: Double, nowMs: Double,
                           cadenceSeconds: Double) -> Bool {
        deliberate || nowMs - lastSentAtMs >= cadenceSeconds * 1000
    }

    /// The least spacing between two whole-pot writes, in seconds. A burst
    /// of writers within it becomes one trailing write with the latest
    /// state. Measured: four pots in six seconds, one per writer.
    static let minSpacingSeconds: Double = 5

    /// How long a write has to wait, or nil to write now. The spacing is
    /// a parameter so a witness can drive the carrier without waiting.
    static func trailingWait(lastWriteAtMs: Double, nowMs: Double,
                             spacingSeconds: Double = minSpacingSeconds) -> Double? {
        let since = (nowMs - lastWriteAtMs) / 1000
        return since >= spacingSeconds ? nil : spacingSeconds - since
    }
}
