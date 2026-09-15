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
    /// The playlists as ONE whole document (`playlists`, scope ""), written
    /// with compare-and-set like the stands. The body is opaque here: the
    /// carrier encodes and decodes it, the session only holds the last it
    /// saw so the runner's synchronous rule answers at once. On a version
    /// that moved under a write the session takes what the service holds and
    /// nudges the runner, which re-merges with `MaerPlaylistMerge` and writes
    /// again; the merge stays out of the session.
    nonisolated static let playlistsKind = "playlists"
    nonisolated static let playlistsMirrorKey = "maerSyncPlaylists"
    nonisolated static let playlistsVersionKey = "maerSyncPlaylistsVersion"
    private(set) var playlistsBody: Data?
    private var playlistsVersion: String?
    private var playlistsPending: Data?
    private var playlistsRun: Task<Void, Never>?
    var onPlaylistsChange: (@MainActor () -> Void)?
    /// The user choices as ONE whole document (`choices`, scope ""), the
    /// same shape as the playlists: an opaque body the carrier encodes and
    /// decodes, compare-and-set, and on a version that moved the session
    /// takes what the service holds and nudges the runner, whose
    /// `UserChoiceMerge` decides per key. The merge stays out of the session.
    nonisolated static let choicesKind = "choices"
    nonisolated static let choicesMirrorKey = "maerSyncChoices"
    nonisolated static let choicesVersionKey = "maerSyncChoicesVersion"
    private(set) var choicesBody: Data?
    private var choicesVersion: String?
    private var choicesPending: Data?
    private var choicesRun: Task<Void, Never>?
    var onChoicesChange: (@MainActor () -> Void)?
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
        playlistsBody = defaults.data(forKey: Self.playlistsMirrorKey)
        playlistsVersion = defaults.string(forKey: Self.playlistsVersionKey)
        choicesBody = defaults.data(forKey: Self.choicesMirrorKey)
        choicesVersion = defaults.string(forKey: Self.choicesVersionKey)
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
        // The same register the CloudKit carriers use, and for the same
        // reason: the start is not the only occasion. ONE entry for the whole
        // session, because a round here serves every document at once, and a
        // round reopens the socket that a spell in the background closed.
        // Without this the service's documents arrived at the service and
        // showed up on the other device only at its next cold start (T39,
        // measured on two devices; it is T25 on the other transport).
        // Its own gate: a session without access has nothing to fetch, and
        // the iCloud switch says nothing about this transport.
        CarrierRefreshers.register(self, zone: Self.serviceZone,
                                   gate: { [weak self] in self?.access != nil }) { [weak self] caller in
            await self?.refresh(by: caller)
        }
        Task { await self.refresh(by: "start") }
    }

    /// The register's name for this session. Not a CloudKit zone: a push
    /// never names it, so it is woken by the occasions that name no zone.
    static let serviceZone = "maer-sync-service"

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
            await self.flushPlaylists(by: caller)
            await self.flushChoices(by: caller)
            for family in self.families { await self.flush(family, by: caller) }
            await self.takeStands(by: caller)
            if await self.takePlaylists(by: caller) { self.onPlaylistsChange?() }
            if await self.takeChoices(by: caller) { self.onChoicesChange?() }
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
        case Self.playlistsKind:
            guard announcement.version != playlistsVersion else { return }
            Task { if await self.takePlaylists(by: "announcement") { self.onPlaylistsChange?() } }
        case Self.choicesKind:
            guard announcement.version != choicesVersion else { return }
            Task { if await self.takeChoices(by: "announcement") { self.onChoicesChange?() } }
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

    // MARK: - The playlists (one whole document)

    /// The own snapshot, on its way at once. The session holds the body
    /// optimistically, so the runner's next synchronous read sees what it
    /// just stored; a version that moved is taken and the runner nudged.
    func writePlaylists(_ body: Data, by caller: String) {
        playlistsPending = body
        playlistsBody = body
        persist()
        Task { await self.flushPlaylists(by: caller) }
    }

    private func flushPlaylists(by caller: String) async {
        let previous = playlistsRun
        let run = Task {
            await previous?.value
            await self.sendPlaylists(by: caller)
        }
        playlistsRun = run
        await run.value
    }

    private func sendPlaylists(by caller: String) async {
        guard !unauthorized else { return }
        var attempt = 0
        while let access, let body = playlistsPending, attempt < Self.writeAttempts {
            do {
                switch try await transport.write(kind: Self.playlistsKind, scope: "", body: body,
                                                 format: MaerSyncPlaylistWire.format, ifMatch: playlistsVersion,
                                                 declaredShrink: true, access: access) {
                case .written(let etag):
                    playlistsVersion = etag
                    if playlistsPending == body { playlistsPending = nil }
                    if lastRefusal?.kind == Self.playlistsKind { lastRefusal = nil }
                    persist()
                    Logger.library.notice("MAERSYNC playlists written bytes=\(body.count) version=\(etag, privacy: .public) by=\(caller, privacy: .public)")
                case .stale:
                    // A version moved under the write: take what the service
                    // holds and let the runner re-merge and write again. The
                    // merge is the runner's rule, never the session's.
                    //
                    // The runner is asked WHETHER OR NOT the re-read reports a
                    // foreign change. "My write did not land" and "the document
                    // moved since I last read it" are different questions, and
                    // taking answers only the second: a device that had already
                    // read this version gets `false`, and the own write, whose
                    // body was just dropped, was gone without a trace (T37,
                    // measured at the service: four refusals, three repeated,
                    // the playlists never).
                    attempt += 1
                    playlistsPending = nil
                    _ = await takePlaylists(by: caller)
                    onPlaylistsChange?()
                case .refused(let reason):
                    // A shrink below the floor or a format the service holds
                    // newer. Playlists MAY shrink (a deletion), so a refusal
                    // here is the newer-format case: nothing is declared, the
                    // runner keeps its lists, the write does not clobber.
                    lastRefusal = MaerSyncRefusal(kind: Self.playlistsKind, reason: reason, at: Date())
                    Logger.library.error("MAERSYNC playlists refused reason=\(reason, privacy: .public) by=\(caller, privacy: .public)")
                    playlistsPending = nil
                    return
                }
            } catch {
                note(error, on: "playlists write", by: caller)
                return
            }
        }
    }

    /// The service's playlists document into the mirror. Returns whether it
    /// changed, so the caller can wake the runner. Unreadable is not empty:
    /// the body stays and so does the version, so the next write names a
    /// version that moved and comes back here rather than overwriting what
    /// it never read.
    @discardableResult
    private func takePlaylists(by caller: String) async -> Bool {
        guard let access else { return false }
        let fetched: MaerSyncDocument?
        do {
            fetched = try await transport.fetch(kind: Self.playlistsKind, scope: "", access: access)
        } catch {
            note(error, on: "playlists fetch", by: caller)
            return false
        }
        guard let fetched else {
            // The service holds none yet: the next write is the first.
            if playlistsVersion != nil { playlistsVersion = nil; persist() }
            return false
        }
        guard fetched.etag != playlistsVersion else { return false }
        playlistsBody = fetched.body
        playlistsVersion = fetched.etag
        persist()
        Logger.library.notice("MAERSYNC playlists fetched bytes=\(fetched.body.count) version=\(fetched.etag, privacy: .public) by=\(caller, privacy: .public)")
        return true
    }

    // MARK: - The choices (one whole document)

    /// The own blob, on its way at once. Held optimistically like the
    /// playlists, so the runner's next synchronous read sees what it just
    /// stored; a version that moved is taken and the runner nudged. Notes
    /// arrive in bursts (a sort, a rate); only the latest pending body is
    /// sent, the chain sends one at a time.
    func writeChoices(_ body: Data, by caller: String) {
        choicesPending = body
        choicesBody = body
        persist()
        Task { await self.flushChoices(by: caller) }
    }

    private func flushChoices(by caller: String) async {
        let previous = choicesRun
        let run = Task {
            await previous?.value
            await self.sendChoices(by: caller)
        }
        choicesRun = run
        await run.value
    }

    private func sendChoices(by caller: String) async {
        guard !unauthorized else { return }
        var attempt = 0
        while let access, let body = choicesPending, attempt < Self.writeAttempts {
            do {
                switch try await transport.write(kind: Self.choicesKind, scope: "", body: body,
                                                 format: MaerSyncChoiceWire.format, ifMatch: choicesVersion,
                                                 declaredShrink: true, access: access) {
                case .written(let etag):
                    choicesVersion = etag
                    if choicesPending == body { choicesPending = nil }
                    if lastRefusal?.kind == Self.choicesKind { lastRefusal = nil }
                    persist()
                    Logger.library.notice("MAERSYNC choices written bytes=\(body.count) version=\(etag, privacy: .public) by=\(caller, privacy: .public)")
                case .stale:
                    // Same shape and same reason as the playlists above: the
                    // runner is asked either way, because taking answers
                    // "did the document move", not "did my write land". This
                    // path happened to work at the bench only because the
                    // re-read did report a change there.
                    attempt += 1
                    choicesPending = nil
                    _ = await takeChoices(by: caller)
                    onChoicesChange?()
                case .refused(let reason):
                    // The blob MAY shrink (the rate cap prunes, a tombstone
                    // ages out), so a refusal here is the newer-format case:
                    // nothing is declared, the runner keeps its state, the
                    // write does not clobber.
                    lastRefusal = MaerSyncRefusal(kind: Self.choicesKind, reason: reason, at: Date())
                    Logger.library.error("MAERSYNC choices refused reason=\(reason, privacy: .public) by=\(caller, privacy: .public)")
                    choicesPending = nil
                    return
                }
            } catch {
                note(error, on: "choices write", by: caller)
                return
            }
        }
    }

    /// The service's choices document into the mirror. Returns whether it
    /// changed, so the caller can wake the runner. Unreadable is not empty:
    /// body and version stay, so the next write names a version that moved
    /// and comes back here rather than overwriting what it never read.
    @discardableResult
    private func takeChoices(by caller: String) async -> Bool {
        guard let access else { return false }
        let fetched: MaerSyncDocument?
        do {
            fetched = try await transport.fetch(kind: Self.choicesKind, scope: "", access: access)
        } catch {
            note(error, on: "choices fetch", by: caller)
            return false
        }
        guard let fetched else {
            if choicesVersion != nil { choicesVersion = nil; persist() }
            return false
        }
        guard fetched.etag != choicesVersion else { return false }
        choicesBody = fetched.body
        choicesVersion = fetched.etag
        persist()
        Logger.library.notice("MAERSYNC choices fetched bytes=\(fetched.body.count) version=\(fetched.etag, privacy: .public) by=\(caller, privacy: .public)")
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
        if let playlistsBody {
            defaults.set(playlistsBody, forKey: Self.playlistsMirrorKey)
        } else {
            defaults.removeObject(forKey: Self.playlistsMirrorKey)
        }
        if let playlistsVersion {
            defaults.set(playlistsVersion, forKey: Self.playlistsVersionKey)
        } else {
            defaults.removeObject(forKey: Self.playlistsVersionKey)
        }
        if let choicesBody {
            defaults.set(choicesBody, forKey: Self.choicesMirrorKey)
        } else {
            defaults.removeObject(forKey: Self.choicesMirrorKey)
        }
        if let choicesVersion {
            defaults.set(choicesVersion, forKey: Self.choicesVersionKey)
        } else {
            defaults.removeObject(forKey: Self.choicesVersionKey)
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

/// The Mär playlists on the service: ONE whole document over the session's
/// `playlists` channel. The far side is what the session last fetched; a
/// store hands the merged snapshot to the session, which compare-and-sets
/// it. The merge (`MaerPlaylistMerge`) stays in the runner, so this carrier
/// only encodes, decodes and forwards.
@MainActor
final class MaerSyncPlaylistCarrier: PlaylistCarrier {
    private let session: MaerSyncSession

    init(session: MaerSyncSession) {
        self.session = session
    }

    var name: String { session.name }

    func held() -> MaerPlaylistMerge.Snapshot {
        guard let body = session.playlistsBody else { return MaerPlaylistMerge.Snapshot() }
        // Unreadable reads as nothing HERE, but the runner's write of the
        // local state then meets the service's format gate (an older format
        // never lands), so a body this build cannot read is not overwritten.
        return MaerSyncPlaylistWire.decode(body) ?? MaerPlaylistMerge.Snapshot()
    }

    func store(_ snapshot: MaerPlaylistMerge.Snapshot) {
        do {
            session.writePlaylists(try MaerSyncPlaylistWire.encode(snapshot), by: "reconcile")
        } catch {
            Logger.library.error("MAERSYNC playlists not encodable")
        }
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        session.onPlaylistsChange = onChange
        session.start()
    }

    func refresh(by caller: String) async {
        await session.refresh(by: caller)
    }
}

/// The playlists snapshot on the wire: the SAME plist-shaped dictionaries
/// the key-value blob uses (so one tolerant shape serves both ways), as
/// JSON with sorted keys, so the same snapshot gives the same bytes and a
/// needless write is a byte-for-byte match the runner already skips. A
/// field added later reads through the tolerant helpers, never throws.
/// Format 1.
nonisolated enum MaerSyncPlaylistWire {
    static let format = 1

    static func encode(_ snapshot: MaerPlaylistMerge.Snapshot) throws -> Data {
        var lists: [String: Any] = [:]
        for (id, entry) in snapshot.lists {
            var payload: [String: Any] = ["name": entry.name, "updatedAt": entry.updatedAt,
                                          "items": entry.itemIds, "titles": entry.titles,
                                          "snapshots": KeyValuePlaylistCarrier.blob(snapshots: entry.snapshots),
                                          "device": entry.device ?? ""]
            if let nameUpdatedAt = entry.nameUpdatedAt { payload["nameUpdatedAt"] = nameUpdatedAt }
            if !entry.removed.isEmpty { payload["removed"] = entry.removed }
            if !entry.added.isEmpty { payload["added"] = entry.added }
            lists[id] = payload
        }
        let object: [String: Any] = ["lists": lists, "tombstones": snapshot.tombstones]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> MaerPlaylistMerge.Snapshot? {
        // tragbar, weil ein unlesbarer Rumpf keine Momentaufnahme ist: der Traeger liest nil als leer, und die Format-Sperre des Dienstes haelt den aelteren Schrieb ab
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var snapshot = MaerPlaylistMerge.Snapshot()
        for (id, value) in (object["lists"] as? [String: Any]) ?? [:] {
            guard let dict = value as? [String: Any],
                  let name = dict["name"] as? String,
                  let updatedAt = (dict["updatedAt"] as? NSNumber)?.doubleValue,
                  let items = dict["items"] as? [String] else { continue }
            let device = dict["device"] as? String
            snapshot.lists[id] = .init(name: name, updatedAt: updatedAt, itemIds: items,
                                       titles: (dict["titles"] as? [String: String]) ?? [:],
                                       nameUpdatedAt: (dict["nameUpdatedAt"] as? NSNumber)?.doubleValue,
                                       snapshots: KeyValuePlaylistCarrier.snapshots(fromBlob: dict["snapshots"]),
                                       removed: KeyValuePlaylistCarrier.moments(fromBlob: dict["removed"]),
                                       added: KeyValuePlaylistCarrier.moments(fromBlob: dict["added"]),
                                       device: (device?.isEmpty ?? true) ? nil : device)
        }
        for (id, value) in (object["tombstones"] as? [String: Any]) ?? [:] {
            if let stamp = (value as? NSNumber)?.doubleValue { snapshot.tombstones[id] = stamp }
        }
        return snapshot
    }
}

/// The user choices on the service: ONE whole document over the session's
/// `choices` channel. The far side is what the session last fetched; the
/// runner hands the merged blob to the session, which compare-and-sets it.
/// The merge (`UserChoiceMerge`) stays in the runner, so this carrier only
/// encodes, decodes and forwards. The old premium-classification lists
/// were only ever in the key-value store, so here they read as none.
@MainActor
final class MaerSyncChoiceCarrier: ChoiceCarrier {
    private let session: MaerSyncSession

    init(session: MaerSyncSession) {
        self.session = session
    }

    var name: String { session.name }

    func loadBlob() -> [String: Any] {
        guard let body = session.choicesBody else { return [:] }
        // Unreadable reads as nothing HERE, but the runner's write of the
        // local state then meets the service's format gate (an older format
        // never lands), so a body this build cannot read is not overwritten.
        return MaerSyncChoiceWire.decode(body) ?? [:]
    }

    func storeBlob(_ blob: [String: Any]) {
        do {
            session.writeChoices(try MaerSyncChoiceWire.encode(blob), by: "reconcile")
        } catch {
            Logger.library.error("MAERSYNC choices not encodable")
        }
    }

    func legacyList(forKey key: String) -> [String]? { nil }

    /// The session sends its own write and coalesces bursts by itself;
    /// nothing waits here to be flushed.
    func flush() {}

    func start(onChange: @escaping @MainActor () -> Void) {
        session.onChoicesChange = onChange
        session.start()
    }
}

/// The choices blob on the wire: every entry as `{t, v}` like the key-value
/// blob, but with the value TAGGED by its type (`s` string, `b` bool, `i`
/// int, `d` double, `l` string list, `x` data as base64), because JSON
/// blurs bool and int and cannot hold data, and the merge's equal-value
/// guard must read back exactly what was written. A tombstone has no `v`.
/// Sorted keys, so the same blob gives the same bytes. Format 1.
nonisolated enum MaerSyncChoiceWire {
    static let format = 1

    static func encode(_ blob: [String: Any]) throws -> Data {
        var entries: [String: Any] = [:]
        for (key, raw) in blob {
            guard let entry = UserChoiceEntry.from(plist: raw) else { continue }
            var payload: [String: Any] = ["t": entry.t]
            if let value = entry.value { payload["v"] = tagged(value) }
            entries[key] = payload
        }
        return try JSONSerialization.data(withJSONObject: ["entries": entries], options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> [String: Any]? {
        // tragbar, weil ein unlesbarer Rumpf kein Blob ist: der Traeger liest nil als leer, und die Format-Sperre des Dienstes haelt den aelteren Schrieb ab
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["entries"] as? [String: Any] else { return nil }
        var blob: [String: Any] = [:]
        for (key, raw) in entries {
            guard let dict = raw as? [String: Any],
                  let t = (dict["t"] as? NSNumber)?.doubleValue else { continue }
            var value: UserChoiceValue?
            if let tag = dict["v"] {
                // An unknown tag is a value this build cannot read; the
                // entry is skipped, never turned into a tombstone.
                guard let read = untagged(tag) else { continue }
                value = read
            }
            blob[key] = UserChoiceEntry(value: value, t: t).plist
        }
        return blob
    }

    static func tagged(_ value: UserChoiceValue) -> [String: Any] {
        switch value {
        case .string(let v): return ["s": v]
        case .bool(let v): return ["b": v]
        case .int(let v): return ["i": v]
        case .double(let v): return ["d": v]
        case .stringList(let v): return ["l": v]
        case .data(let v): return ["x": v.base64EncodedString()]
        }
    }

    /// The tag decides the type, so an NSNumber is read as what the tag
    /// says and never guessed at.
    static func untagged(_ raw: Any) -> UserChoiceValue? {
        guard let dict = raw as? [String: Any], dict.count == 1, let first = dict.first else { return nil }
        switch first.key {
        case "s": return (first.value as? String).map(UserChoiceValue.string)
        case "b": return (first.value as? NSNumber).map { .bool($0.boolValue) }
        case "i": return (first.value as? NSNumber).map { .int($0.intValue) }
        case "d": return (first.value as? NSNumber).map { .double($0.doubleValue) }
        case "l": return (first.value as? [String]).map(UserChoiceValue.stringList)
        case "x": return (first.value as? String).flatMap { Data(base64Encoded: $0) }.map(UserChoiceValue.data)
        default: return nil
        }
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
