// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// The one channel of playback notices: what the pill shows, the stopping
/// error behind it, and the log of every notice. Owned by the coordinator;
/// the player model only says what happened. `NoticeRule` decides, this
/// type keeps the state, the timer and the log.
@MainActor
final class PlaybackNotices: ObservableObject {
    @Published private(set) var shown: PlaybackNotice?
    @Published private(set) var log: [NoticeLogEntry]

    private var state = NoticeRule.State()
    private let expirySeconds: Double
    private let stallHintSeconds: Double
    /// When the player began to wait on the stream; nil while it does not.
    private var stallSince: Date?
    private let ablage: Ablage
    private let now: () -> Date
    private var pendingSave: Task<Void, Never>?
    /// Hands the log to the account that holds the device's stock, like
    /// every family on the shelf: what was said under another account rests
    /// there and comes back with it; nothing is deleted. Nil: the log stays
    /// with whoever wrote it (a witness without a shelf).
    private let follower: ShelfFollower?
    /// The account signed in now; a witness hands in its own.
    private let identity: () -> String?
    /// A hand-over that could not happen (the shelf did not take the rest):
    /// the owner before it, tried again before the next line is written,
    /// so no line said under the new account joins the holder's log.
    private var heldFrom: String??

    /// The document the log lives in. It stands in no list of the carriers
    /// or the choices: it stays on this device.
    static let documentName = "playback-notices"
    nonisolated static let shelfFamily = "playback-notices"

    init(expirySeconds: Double = 4, stallHintSeconds: Double = StallRule.hintAfterSeconds,
         ablage: Ablage = .documents, shelf: RestingShelf? = nil,
         identity: @escaping () -> String? = { AccessFollowers.identity },
         now: @escaping () -> Date = Date.init) {
        self.expirySeconds = expirySeconds
        self.stallHintSeconds = stallHintSeconds
        self.ablage = ablage
        self.identity = identity
        self.now = now
        follower = shelf.map { ShelfFollower(family: Self.shelfFamily, shelf: $0, label: "NOTICES") }
        let read = ablage.loadNow([NoticeLogEntry].self, name: Self.documentName)
        if case .corrupt = read {
            Logger.player.error("NOTICES log unreadable, starts empty this run")
        }
        log = NoticeLogEntry.trimmed(read.value ?? [], now: now().timeIntervalSince1970)
    }

    // MARK: - Owner (the log follows the account like every family)

    /// Hands the log to `scope` by the shelf's one rule
    /// (`RestingShelf.handOver`). The stock of this run is always whole: an
    /// unreadable document lies aside by the rule of the seam and this run
    /// starts empty, so no hand-over waits for a read. False while the
    /// hand-over cannot happen; it is tried again before the next line.
    @discardableResult
    func follow(owner scope: String, previous: String? = nil) -> Bool {
        guard let follower else { return true }
        let before = log.count
        guard let step = follower.follow(
            to: scope, previous: previous, unread: false, landing: .marked,
            current: { log },
            replace: { rest, _, name in replace(with: rest, replacement: name) }) else {
            heldFrom = .some(previous)
            Logger.player.notice("NOTICES owner held, tried again before the next line")
            return false
        }
        heldFrom = nil
        switch step {
        case .kept, .unread: break
        case .first: Logger.player.notice("NOTICES owner first lines=\(before)")
        case .moved: Logger.player.notice("NOTICES owner moved rested=\(before) lines=\(self.log.count)")
        }
        return true
    }

    /// The lines of the new owner replace the ones here; the holding settles
    /// once their save landed, after every save queued before it.
    private func replace(with rest: [NoticeLogEntry]?, replacement name: String) {
        log = NoticeLogEntry.trimmed(rest ?? [], now: now().timeIntervalSince1970)
        queueSave(log) { [weak follower] in follower?.markLanded(name) }
    }

    /// At start: the log follows the account signed in now, against the
    /// device's stock owner; signed out, it stays with the stock.
    func followAtStart() {
        guard let scope = identity() else { return }
        follow(owner: scope, previous: StockOwner.owner(in: .standard))
    }

    /// A held hand-over, tried again.
    private func followIfHeld() {
        guard let previous = heldFrom, let scope = identity() else { return }
        follow(owner: scope, previous: previous)
    }

    /// A notice happened. It goes into the log; the rule says whether and
    /// how it shows.
    func show(_ notice: PlaybackNotice, title: String?) {
        append(notice, title: title)
        apply(.show(notice))
        guard shown == notice, !NoticeRule.answer(notice.kind).holdsUntilPlay else { return }
        later(expirySeconds) { [weak self] in self?.apply(.expired(notice)) }
    }

    /// The player waits on the stream, or no longer does. The model only
    /// says so; the hint comes from here once the wait has lasted the rule's
    /// time, and goes when the wait ends.
    func streamWaits(_ waits: Bool, title: String?) {
        guard waits else {
            stallSince = nil
            apply(.streamResumed)
            return
        }
        guard stallSince == nil else { return }
        let since = now()
        stallSince = since
        later(stallHintSeconds) { [weak self] in
            guard let self, self.stallSince == since,
                  StallRule.hints(waitedSeconds: self.now().timeIntervalSince(since), hintAfter: self.stallHintSeconds)
            else { return }
            // The hint stands until the wait ends; playback is never stopped.
            self.show(.waitingForNetwork, title: title)
        }
    }

    /// Playback started: a stopping error falls.
    func played() { apply(.played) }

    /// Another title took over (or none is held any more).
    func titleChanged() {
        stallSince = nil
        apply(.titleChanged)
    }

    /// The channel's one timer: the end of a short notice and the time a
    /// wait on the stream takes before the hint.
    private func later(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            action()
        }
    }

    private func apply(_ event: NoticeRule.Event) {
        let next = NoticeRule.next(state, event)
        state = next
        if shown != next.shown { shown = next.shown }
    }

    private func append(_ notice: PlaybackNotice, title: String?) {
        followIfHeld()
        let at = now().timeIntervalSince1970
        log = NoticeLogEntry.trimmed(log + [NoticeLogEntry(id: UUID(), at: at, kind: notice.kind, label: notice.label,
                                                           icon: notice.icon, title: title)], now: at)
        queueSave(log)
    }

    /// Saves in order, one after the other. `landed` hears a save that
    /// stands on disk; an empty log refused over an unreadable file counts
    /// as landed, because no readable line stands there either.
    private func queueSave(_ snapshot: [NoticeLogEntry], landed: (@MainActor () -> Void)? = nil) {
        let previous = pendingSave
        pendingSave = Task { [ablage] in
            await previous?.value
            do {
                try await ablage.save(snapshot, name: Self.documentName, isEmpty: snapshot.isEmpty)
                landed?()
            } catch AblageError.blockedByCorruptFile where snapshot.isEmpty {
                landed?()
            } catch {
                Logger.player.error("NOTICES log not saved reason=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// For witnesses: the log has landed on disk.
    func awaitPendingSave() async { await pendingSave?.value }
}

extension PlaybackNotices: AccessFollower {
    var followerName: String { "playback-notices" }

    /// The log follows a change of account at the moment of the change.
    func followOwner(previous: String?) {
        guard let scope = identity() else { return }
        follow(owner: scope, previous: previous)
    }

    /// No carrier: the log stays on this device. A held hand-over is tried
    /// again at every change of way, besides before the next line.
    func followAccess(signedIn: Bool, identityChanged: Bool, by caller: String) {
        followIfHeld()
    }
}
