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
    /// Every device's claim as far as this device knows, by device.
    private(set) var claims: [String: PlaybackClaim] = [:]
    private var claimVersions: [String: String] = [:]
    private var pendingClaim: PlaybackClaim?
    private var ownClaimVersion: String?
    var onStandsChange: (@MainActor () -> Void)?
    var onClaimsChange: (@MainActor () -> Void)?
    private var started = false
    private var refreshRun: Task<Void, Never>?
    private var standsRun: Task<Void, Never>?
    private var claimRun: Task<Void, Never>?
    /// The service refused the token: nothing runs until the person signs
    /// in again, which is `reloadAccess()`.
    private(set) var unauthorized = false

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
            await self.flushClaim(by: caller)
            await self.takeStands(by: caller)
            await self.takeClaims(by: caller)
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
        case Self.claimKind:
            guard announcement.scope != deviceId(),
                  claimVersions[announcement.scope] != announcement.version else { return }
            Task {
                if await self.takeClaim(scope: announcement.scope, by: "announcement") {
                    self.onClaimsChange?()
                }
            }
        default:
            break
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
                    persist()
                    Logger.library.notice("MAERSYNC stands written entries=\(document.count) bytes=\(body.count) version=\(etag, privacy: .public) by=\(caller, privacy: .public)")
                case .stale:
                    attempt += 1
                    guard await takeStands(by: caller) else { return }
                case .refused(let reason):
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

    // MARK: - The claims

    /// The own claim, on its way at once. A newer one written while the
    /// last is still travelling replaces it in the queue of one.
    func writeClaim(_ claim: PlaybackClaim, by caller: String) {
        pendingClaim = claim
        claims[claim.deviceId] = claim
        Task { await self.flushClaim(by: caller) }
    }

    private func flushClaim(by caller: String) async {
        let previous = claimRun
        let run = Task {
            await previous?.value
            await self.sendClaim(by: caller)
        }
        claimRun = run
        await run.value
    }

    private func sendClaim(by caller: String) async {
        guard !unauthorized else { return }
        var attempt = 0
        while let access, let claim = pendingClaim, attempt < Self.writeAttempts {
            let body: Data
            do {
                body = try MaerSyncClaimWire.encode(claim)
            } catch {
                Logger.library.error("MAERSYNC claim not encodable by=\(caller, privacy: .public)")
                pendingClaim = nil
                return
            }
            do {
                // A claim is a signal, not a state: a release is smaller
                // than the play it withdraws, and that is meant. The stands
                // never declare a shrink; the claim always does.
                switch try await transport.write(kind: Self.claimKind, scope: claim.deviceId, body: body,
                                                 format: MaerSyncClaimWire.format, ifMatch: ownClaimVersion,
                                                 declaredShrink: true, access: access) {
                case .written(let etag):
                    ownClaimVersion = etag
                    if pendingClaim == claim { pendingClaim = nil }
                case .stale(let current):
                    // The own document is only ever written by this device;
                    // a version that moved is a restart that forgot it. The
                    // stored one is taken and the write repeated, because
                    // what this device plays now is newer than anything it
                    // wrote before.
                    attempt += 1
                    if let current {
                        ownClaimVersion = current
                    } else {
                        ownClaimVersion = try await transport.fetch(kind: Self.claimKind, scope: claim.deviceId,
                                                                    access: access)?.etag
                    }
                case .refused(let reason):
                    Logger.library.error("MAERSYNC claim refused reason=\(reason, privacy: .public) by=\(caller, privacy: .public)")
                    pendingClaim = nil
                    return
                }
            } catch {
                note(error, on: "claim write", by: caller)
                return
            }
        }
    }

    /// The other devices' claims: the listing says which scopes exist and
    /// at which version, and only a version this device has not seen is
    /// fetched. A scope no longer listed is a document that is gone.
    private func takeClaims(by caller: String) async {
        guard let access else { return }
        let listed: [MaerSyncListed]
        do {
            listed = try await transport.list(kind: Self.claimKind, access: access)
        } catch {
            note(error, on: "claim listing", by: caller)
            return
        }
        let own = deviceId()
        var changed = false
        var seen: Set<String> = [own]
        for entry in listed where entry.scope != own {
            seen.insert(entry.scope)
            guard claimVersions[entry.scope] != entry.etag else { continue }
            if await takeClaim(scope: entry.scope, by: caller) { changed = true }
        }
        for scope in claims.keys where !seen.contains(scope) {
            claims[scope] = nil
            claimVersions[scope] = nil
            changed = true
        }
        if changed { onClaimsChange?() }
    }

    private func takeClaim(scope: String, by caller: String) async -> Bool {
        guard let access else { return false }
        do {
            guard let document = try await transport.fetch(kind: Self.claimKind, scope: scope, access: access) else {
                claims[scope] = nil
                claimVersions[scope] = nil
                return true
            }
            guard let claim = MaerSyncClaimWire.decode(document.body) else {
                Logger.library.error("MAERSYNC claim unreadable version=\(document.etag, privacy: .public) by=\(caller, privacy: .public)")
                return false
            }
            claims[scope] = claim
            claimVersions[scope] = document.etag
            return true
        } catch {
            note(error, on: "claim fetch", by: caller)
            return false
        }
    }

    /// Forgets a device's claim here and only here. The service has no
    /// ceiling, so an orphan costs nothing there, and another device's
    /// document is not this device's to delete. The version stays known,
    /// so the next listing does not fetch the same orphan again.
    func forgetClaim(deviceId id: String) {
        claims[id] = nil
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
        Logger.library.notice("MAERSYNC \(what, privacy: .public) failed reason=\(Self.reason(of: error), privacy: .public) by=\(caller, privacy: .public)")
    }

    /// The reason in the log: a code or a type, never an address.
    nonisolated static func reason(of error: Error) -> String {
        if let failure = error as? MaerSyncFailure { return String(describing: failure) }
        if let urlError = error as? URLError { return "urlError=\(urlError.code.rawValue)" }
        return String(describing: type(of: error))
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

    func write(_ claim: PlaybackClaim) {
        session.writeClaim(claim, by: "claim")
    }

    func claims() -> [PlaybackClaim] { Array(session.claims.values) }

    func remove(deviceId: String) {
        session.forgetClaim(deviceId: deviceId)
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        session.onClaimsChange = onChange
        session.start()
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
