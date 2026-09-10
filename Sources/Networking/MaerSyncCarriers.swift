// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The Mär sync service as the third carrier behind `StandCarrier` and
/// `ClaimCarrier`. ONE session serves both: one address, one token, one
/// changes socket, one mirror of what the service holds as far as this
/// device knows. The two carriers are thin views on it, so the runners
/// keep their rules and know nothing of the service.
///
/// The stands are ONE document (`stands`, the whole pot, like the blob),
/// written with compare-and-set: a version that moved under a write is
/// fetched, the queue is merged over it with the pot's own rule (per item
/// the newer moment wins), and the write is repeated. The claim is one
/// document PER DEVICE (`claim`, scope = device id), so no heartbeat can
/// overwrite another device's play; only the own scope is ever written.
///
/// The service has no ceiling, so the carrier has no room limit, and no
/// cadence of its own: a write goes out at once, and a burst of writers
/// finds the queue already on its way. Nothing here reconnects on a
/// timer. The socket is an accelerator; the occasions the runners already
/// have (the start, the foreground, the tick while playing) open it again
/// and fetch what was missed.
@MainActor
final class MaerSyncSession {
    nonisolated static let standsKind = "stands"
    nonisolated static let claimKind = "claim"
    nonisolated static let statsKind = "stats"
    nonisolated static let mirrorKey = "maerSyncStands"
    nonisolated static let versionKey = "maerSyncStandsVersion"
    nonisolated static let queueKey = "maerSyncStandsQueue"
    nonisolated static let removalsKey = "maerSyncStandsQueueRemovals"
    /// How often one round repeats a write against a version that moved
    /// under it. Two devices writing at once need one repeat; the bound
    /// only keeps a service that answers stale forever from spinning.
    nonisolated static let writeAttempts = 4

    private let transport: any MaerSyncTransport
    private let announcer: any MaerSyncAnnouncer
    private let loadAccess: () -> MaerSyncAccess?
    private let deviceId: () -> String
    private let defaults: UserDefaults

    /// Read once and on `reloadAccess()`: the token lives in the keychain,
    /// and a round trip there per refresh is measurable load.
    private(set) var access: MaerSyncAccess?
    /// What the service holds as far as this device knows, with the queue
    /// applied, so the runner's synchronous rule answers at once.
    private(set) var stands: [String: [Double]]
    private var standsVersion: String?
    /// Written here, not yet accepted by the service.
    private var queue: [String: [Double]]
    private var queuedRemovals: Set<String>
    /// A family of documents with one document PER DEVICE (the scope is
    /// the device id): this device writes its own scope and reads every
    /// other. The claim and the statistics are two such families; a third
    /// is one line below.
    final class ScopedFamily {
        let kind: String
        let format: Int
        /// Whether a write may shrink the document. A claim is a signal
        /// (a release is smaller than the play it withdraws); a pot of
        /// statistics only grows, and a shrink there is a fault to show.
        let declaredShrink: Bool
        /// Every device's document as far as this device knows, by scope.
        var bodies: [String: Data] = [:]
        var versions: [String: String] = [:]
        /// The own document on its way; a newer one replaces it.
        var pending: Data?
        var ownVersion: String?
        var run: Task<Void, Never>?
        var onChange: (@MainActor () -> Void)?

        init(kind: String, format: Int, declaredShrink: Bool) {
            self.kind = kind
            self.format = format
            self.declaredShrink = declaredShrink
        }
    }

    let claimFamily = ScopedFamily(kind: MaerSyncSession.claimKind, format: MaerSyncClaimWire.format, declaredShrink: true)
    let statsFamily = ScopedFamily(kind: MaerSyncSession.statsKind, format: MaerSyncStatsWire.format, declaredShrink: false)
    private var families: [ScopedFamily] { [claimFamily, statsFamily] }

    var onStandsChange: (@MainActor () -> Void)?
    private var started = false
    private var refreshRun: Task<Void, Never>?
    private var standsRun: Task<Void, Never>?
    /// The service refused the token: nothing runs until the person signs
    /// in again, which is `reloadAccess()`.
    private(set) var unauthorized = false
    /// The last refused write, until a write of the same kind lands.
    private(set) var lastRefusal: MaerSyncRefusal?

    init(transport: any MaerSyncTransport, announcer: any MaerSyncAnnouncer,
         access: @escaping () -> MaerSyncAccess?, deviceId: @escaping () -> String,
         defaults: UserDefaults = AppStorageKeys.store) {
        self.transport = transport
        self.announcer = announcer
        self.loadAccess = access
        self.deviceId = deviceId
        self.defaults = defaults
        self.access = access()
        stands = StandMirrorStore.load(Self.mirrorKey, defaults: defaults)
        queue = StandMirrorStore.load(Self.queueKey, defaults: defaults)
        queuedRemovals = Set(StandMirrorStore.loadList(Self.removalsKey, defaults: defaults))
        standsVersion = defaults.string(forKey: Self.versionKey)
    }

    /// A short name for the log line that says which carrier runs.
    var name: String { unauthorized ? "maer-sync signed out" : "maer-sync" }

    /// After a sign-in or sign-out: the access is read again and the
    /// rounds may run again. Without an access the socket closes.
    func reloadAccess() {
        access = loadAccess()
        unauthorized = false
        if access == nil { announcer.close() }
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await self.refresh(by: "start") }
    }

    /// One round: the socket if it is not open, the queue, the own claim,
    /// then what the service holds. Rounds form a chain: a caller's round
    /// runs after the one before it, so nobody's occasion is skipped and
    /// no two rounds interleave. A chain, not a flag: a loop that waits
    /// on a finished task while the flag's owner never gets to clear it
    /// spins forever (measured, the first witness hung on it).
    func refresh(by caller: String) async {
        let previous = refreshRun
        let run = Task {
            await previous?.value
            guard let access = self.access, !self.unauthorized else { return }
            if !self.announcer.isOpen { self.openSocket(access) }
            await self.flushStands(by: caller)
            for family in self.families { await self.flush(family, by: caller) }
            await self.takeStands(by: caller)
            for family in self.families { await self.take(family, by: caller) }
        }
        refreshRun = run
        await run.value
    }

    // MARK: - The socket

    private func openSocket(_ access: MaerSyncAccess) {
        announcer.open(access: access, onAnnouncement: { [weak self] announcement in
            self?.took(announcement)
        }, onClose: {
            Logger.library.notice("MAERSYNC socket closed; the next occasion opens it again")
        })
        Logger.library.notice("MAERSYNC socket open host=\(access.baseURL.host ?? "-", privacy: .public)")
    }

    /// An announcement names a document that moved. The own writes come
    /// back too, at the version this device just stored, and are known.
    private func took(_ announcement: MaerSyncAnnouncement) {
        switch announcement.kind {
        case Self.standsKind:
            guard announcement.version != standsVersion else { return }
            Task { await self.takeStands(by: "announcement") }
        default:
            guard let family = families.first(where: { $0.kind == announcement.kind }),
                  announcement.scope != deviceId(),
                  family.versions[announcement.scope] != announcement.version else { return }
            Task {
                if await self.take(family, scope: announcement.scope, by: "announcement") {
                    family.onChange?()
                }
            }
        }
    }

    // MARK: - The stands

    /// Into the mirror and the queue; the write goes out at once.
    func enqueue(upserts: [String: [Double]], removing: Set<String>, by caller: String) {
        for (id, entry) in upserts {
            stands[id] = entry
            queue[id] = entry
            queuedRemovals.remove(id)
        }
        for id in removing {
            stands[id] = nil
            queue[id] = nil
            queuedRemovals.insert(id)
        }
        persist()
        Task { await self.flushStands(by: caller) }
    }

    /// Sends the queue as the whole document with the version this device
    /// knows. A version that moved is taken in and the write repeated; a
    /// refusal keeps the queue and declares nothing, because a pot that
    /// shrank is the loss the gate is there to refuse.
    private func flushStands(by caller: String) async {
        let previous = standsRun
        let run = Task {
            await previous?.value
            await self.sendStands(by: caller)
        }
        standsRun = run
        await run.value
    }

    private func sendStands(by caller: String) async {
        guard !unauthorized else { return }
        var attempt = 0
        while let access, !(queue.isEmpty && queuedRemovals.isEmpty), attempt < Self.writeAttempts {
            let sending = queue
            let removing = queuedRemovals
            let document = stands
            let body: Data
            do {
                body = try MaerSyncStandsWire.encode(document)
            } catch {
                Logger.library.error("MAERSYNC stands not encodable entries=\(document.count) by=\(caller, privacy: .public); the queue waits")
                return
            }
            do {
                switch try await transport.write(kind: Self.standsKind, scope: "", body: body,
                                                 format: MaerSyncStandsWire.format, ifMatch: standsVersion,
                                                 declaredShrink: false, access: access) {
                case .written(let etag):
                    standsVersion = etag
                    for (id, entry) in sending where queue[id] == entry { queue[id] = nil }
                    queuedRemovals.subtract(removing)
                    if lastRefusal?.kind == Self.standsKind { lastRefusal = nil }
                    persist()
                    Logger.library.notice("MAERSYNC stands written entries=\(document.count) bytes=\(body.count) version=\(etag, privacy: .public) by=\(caller, privacy: .public)")
                case .stale:
                    attempt += 1
                    guard await takeStands(by: caller) else { return }
                case .refused(let reason):
                    lastRefusal = MaerSyncRefusal(kind: Self.standsKind, reason: reason, at: Date())
                    Logger.library.error("MAERSYNC stands refused reason=\(reason, privacy: .public) queued=\(self.queue.count) by=\(caller, privacy: .public); nothing is declared, the queue waits")
                    return
                }
            } catch {
                note(error, on: "stands write", by: caller)
                return
            }
        }
        if attempt >= Self.writeAttempts {
            Logger.library.notice("MAERSYNC stands gave up after \(attempt) moved versions by=\(caller, privacy: .public); the queue waits for the next occasion")
        }
    }

    /// The service's stands into the mirror, the queue laid over them
    /// with the pot's rule. Returns whether the service answered.
    @discardableResult
    private func takeStands(by caller: String) async -> Bool {
        guard let access else { return false }
        let fetched: MaerSyncDocument?
        do {
            fetched = try await transport.fetch(kind: Self.standsKind, scope: "", access: access)
        } catch {
            note(error, on: "stands fetch", by: caller)
            return false
        }
        guard let fetched else {
            // The service holds no pot yet: the next write is the first.
            standsVersion = nil
            persist()
            return true
        }
        guard fetched.etag != standsVersion else { return true }
        let served: [String: [Double]]
        do {
            served = try MaerSyncStandsWire.decode(fetched.body)
        } catch {
            // Unreadable is not empty: the mirror stays, and so does the
            // version, so the next write names a version that moved and
            // comes back here rather than overwriting what it never read.
            Logger.library.error("MAERSYNC stands unreadable version=\(fetched.etag, privacy: .public) bytes=\(fetched.body.count) by=\(caller, privacy: .public); the mirror stays")
            return false
        }
        // Per item the newer moment wins, the service wins a tie: the same
        // rule the cloud carrier lays its blob over its records with.
        var merged = CloudKitStandCarrier.union(cloud: served, legacy: queue)
        for id in queuedRemovals { merged[id] = nil }
        let before = stands
        stands = merged
        standsVersion = fetched.etag
        persist()
        Logger.library.notice("MAERSYNC stands fetched entries=\(served.count) version=\(fetched.etag, privacy: .public) by=\(caller, privacy: .public)")
        if merged != before { onStandsChange?() }
        return true
    }

    // MARK: - The families with one document per device

    /// Every device's claim as far as this device knows, by device.
    var claims: [String: PlaybackClaim] {
        claimFamily.bodies.compactMapValues(MaerSyncClaimWire.decode)
    }

    /// The own claim, on its way at once. A newer one written while the
    /// last is still travelling replaces it in the queue of one.
    func writeClaim(_ claim: PlaybackClaim, by caller: String) {
        do {
            write(claimFamily, scope: claim.deviceId, body: try MaerSyncClaimWire.encode(claim), by: caller)
        } catch {
            Logger.library.error("MAERSYNC claim not encodable by=\(caller, privacy: .public)")
        }
    }

    /// Forgets a device's claim here and only here. The service has no
    /// ceiling, so an orphan costs nothing there, and another device's
    /// document is not this device's to delete. The version stays known,
    /// so the next listing does not fetch the same orphan again.
    func forgetClaim(deviceId id: String) {
        claimFamily.bodies[id] = nil
    }

    /// Every device's statistics pot as bytes, by device; the carrier
    /// decodes, so the session knows nothing of what a pot is.
    var statsBodies: [String: Data] { statsFamily.bodies }

    func writeStats(_ body: Data, deviceId: String, by caller: String) {
        write(statsFamily, scope: deviceId, body: body, by: caller)
    }

    /// The own document of a family, on its way at once.
    private func write(_ family: ScopedFamily, scope: String, body: Data, by caller: String) {
        family.pending = body
        family.bodies[scope] = body
        Task { await self.flush(family, by: caller) }
    }

    private func flush(_ family: ScopedFamily, by caller: String) async {
        let previous = family.run
        let run = Task {
            await previous?.value
            await self.send(family, by: caller)
        }
        family.run = run
        await run.value
    }

    private func send(_ family: ScopedFamily, by caller: String) async {
        guard !unauthorized else { return }
        let scope = deviceId()
        var attempt = 0
        while let access, let body = family.pending, attempt < Self.writeAttempts {
            do {
                switch try await transport.write(kind: family.kind, scope: scope, body: body,
                                                 format: family.format, ifMatch: family.ownVersion,
                                                 declaredShrink: family.declaredShrink, access: access) {
                case .written(let etag):
                    family.ownVersion = etag
                    if family.pending == body { family.pending = nil }
                    if lastRefusal?.kind == family.kind { lastRefusal = nil }
                case .stale(let current):
                    // The own document is only ever written by this device;
                    // a version that moved is a restart that forgot it. The
                    // stored one is taken and the write repeated, because
                    // what this device holds now is newer than anything it
                    // wrote before.
                    attempt += 1
                    if let current {
                        family.ownVersion = current
                    } else {
                        family.ownVersion = try await transport.fetch(kind: family.kind, scope: scope,
                                                                      access: access)?.etag
                    }
                case .refused(let reason):
                    lastRefusal = MaerSyncRefusal(kind: family.kind, reason: reason, at: Date())
                    Logger.library.error("MAERSYNC \(family.kind, privacy: .public) refused reason=\(reason, privacy: .public) by=\(caller, privacy: .public)")
                    family.pending = nil
                    return
                }
            } catch {
                note(error, on: "\(family.kind) write", by: caller)
                return
            }
        }
    }

    /// The other devices' documents of a family: the listing says which
    /// scopes exist and at which version, and only a version this device
    /// has not seen is fetched. A scope no longer listed is gone.
    private func take(_ family: ScopedFamily, by caller: String) async {
        guard let access else { return }
        let listed: [MaerSyncListed]
        do {
            listed = try await transport.list(kind: family.kind, access: access)
        } catch {
            note(error, on: "\(family.kind) listing", by: caller)
            return
        }
        let own = deviceId()
        var changed = false
        var seen: Set<String> = [own]
        for entry in listed where entry.scope != own {
            seen.insert(entry.scope)
            guard family.versions[entry.scope] != entry.etag else { continue }
            if await take(family, scope: entry.scope, by: caller) { changed = true }
        }
        for scope in family.bodies.keys where !seen.contains(scope) {
            family.bodies[scope] = nil
            family.versions[scope] = nil
            changed = true
        }
        if changed { family.onChange?() }
    }

    private func take(_ family: ScopedFamily, scope: String, by caller: String) async -> Bool {
        guard let access else { return false }
        do {
            guard let document = try await transport.fetch(kind: family.kind, scope: scope, access: access) else {
                family.bodies[scope] = nil
                family.versions[scope] = nil
                return true
            }
            family.bodies[scope] = document.body
            family.versions[scope] = document.etag
            return true
        } catch {
            note(error, on: "\(family.kind) fetch", by: caller)
            return false
        }
    }

    // MARK: - Failures

    private func note(_ error: Error, on what: String, by caller: String) {
        if let failure = error as? MaerSyncFailure, failure == .unauthorized {
            unauthorized = true
            announcer.close()
            Logger.library.error("MAERSYNC signed out: the service refused the token on \(what, privacy: .public) by=\(caller, privacy: .public); nothing runs until the next sign-in")
            return
        }
        guard !error.isCancellation else { return }
        Logger.library.notice("MAERSYNC \(what, privacy: .public) failed reason=\(MaerSyncFailure.reason(of: error), privacy: .public) by=\(caller, privacy: .public)")
    }

    // MARK: - The door

    private func persist() {
        StandMirrorStore.save(stands, key: Self.mirrorKey, defaults: defaults)
        StandMirrorStore.save(queue, key: Self.queueKey, defaults: defaults)
        StandMirrorStore.saveList(Array(queuedRemovals), key: Self.removalsKey, defaults: defaults)
        if let standsVersion {
            defaults.set(standsVersion, forKey: Self.versionKey)
        } else {
            defaults.removeObject(forKey: Self.versionKey)
        }
    }
}

// MARK: - The two carriers

/// The pot on the service. The service has no ceiling, so nothing is
/// pruned, and the sync history names the service rather than iCloud.
@MainActor
final class MaerSyncStandCarrier: StandCarrier {
    private let session: MaerSyncSession

    init(session: MaerSyncSession) {
        self.session = session
    }

    var name: String { session.name }
    var hasRoomLimit: Bool { false }
    var historyService: SyncHistoryEntry.Service { .maerSync }
    /// Every third tick: the socket is the promise here, the pull only
    /// reopens a dead socket and catches up. Chosen, not measured; the
    /// host measurement may move it.
    var pullSeconds: Double { 30 }
    /// Once a minute, like the iCloud carriers: a whole-pot write is a
    /// compare-and-set of the document, and a second per second of
    /// playback would be a document a second. Chosen, not measured.
    var sendCadenceSeconds: Double { 60 }

    func stands() -> [String: [Double]] { session.stands }

    func write(upserts: [String: [Double]], removing: Set<String>, by caller: String) {
        guard !upserts.isEmpty || !removing.isEmpty else { return }
        session.enqueue(upserts: upserts, removing: removing, by: caller)
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        session.onStandsChange = onChange
        session.start()
    }

    func refresh(by caller: String) async {
        await session.refresh(by: caller)
    }
}

/// The claim on the service: one document per device, only the own one
/// written.
@MainActor
final class MaerSyncClaimCarrier: ClaimCarrier {
    private let session: MaerSyncSession

    init(session: MaerSyncSession) {
        self.session = session
    }

    var name: String { session.name }
    /// The service does not throttle, so this is a choice: a jump per
    /// second need not travel as a claim per second, and the socket
    /// delivers each one at once anyway.
    var heartbeatSeconds: Double { 10 }

    func write(_ claim: PlaybackClaim) {
        session.writeClaim(claim, by: "claim")
    }

    func claims() -> [PlaybackClaim] { Array(session.claims.values) }

    func remove(deviceId: String) {
        session.forgetClaim(deviceId: deviceId)
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        session.claimFamily.onChange = onChange
        session.start()
    }
}

/// The statistics on the service: one pot per device, only the own one
/// written, every other read. No ceiling, so nothing is capped and the
/// whole pot travels.
@MainActor
final class MaerSyncStatsCarrier: StatsCarrier {
    private let session: MaerSyncSession

    init(session: MaerSyncSession) {
        self.session = session
    }

    var name: String { session.name }
    var hasRoomLimit: Bool { false }

    func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String) {
        do {
            session.writeStats(try MaerSyncStatsWire.encode(pot), deviceId: deviceId, by: caller)
        } catch {
            Logger.library.error("MAERSYNC stats not encodable by=\(caller, privacy: .public)")
        }
    }

    func pots() -> [String: ListeningStatsData] {
        session.statsBodies.compactMapValues(MaerSyncStatsWire.decode)
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        session.statsFamily.onChange = onChange
        session.start()
    }

    func refresh(by caller: String) async {
        await session.refresh(by: caller)
    }
}

/// The one session of the app, built on first use over the door's
/// transport and socket. Both carriers take it by init, so a witness
/// hands in a session over fakes and nothing here is reached by name
/// from a view.
@MainActor
enum MaerSyncCarriers {
    static let session = MaerSyncSession(transport: MaerSyncHTTP(), announcer: MaerSyncSocket(),
                                         access: { MaerSyncAccess.stored() },
                                         deviceId: { SyncHistoryStore.deviceId })
}
