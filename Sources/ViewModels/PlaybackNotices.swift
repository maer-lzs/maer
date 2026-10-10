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

    /// The document the log lives in. It stands in no list of the carriers
    /// or the choices: it stays on this device.
    static let documentName = "playback-notices"

    init(expirySeconds: Double = 4, stallHintSeconds: Double = StallRule.hintAfterSeconds,
         ablage: Ablage = .documents, now: @escaping () -> Date = Date.init) {
        self.expirySeconds = expirySeconds
        self.stallHintSeconds = stallHintSeconds
        self.ablage = ablage
        self.now = now
        let read = ablage.loadNow([NoticeLogEntry].self, name: Self.documentName)
        if case .corrupt = read {
            Logger.player.error("NOTICES log unreadable, starts empty this run")
        }
        log = NoticeLogEntry.trimmed(read.value ?? [], now: now().timeIntervalSince1970)
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
        let at = now().timeIntervalSince1970
        log = NoticeLogEntry.trimmed(log + [NoticeLogEntry(id: UUID(), at: at, kind: notice.kind, label: notice.label,
                                                           icon: notice.icon, title: title)], now: at)
        let snapshot = log
        let previous = pendingSave
        pendingSave = Task { [ablage] in
            await previous?.value
            do {
                try await ablage.save(snapshot, name: Self.documentName, isEmpty: snapshot.isEmpty)
            } catch {
                Logger.player.error("NOTICES log not saved reason=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// For witnesses: the log has landed on disk.
    func awaitPendingSave() async { await pendingSave?.value }
}
