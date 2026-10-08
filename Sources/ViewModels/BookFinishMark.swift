// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// "Mark as finished" and back for a book: the one door for the detail page
/// and the tile menu of every book cell. Where the mark goes is decided by
/// `step` (pure); `apply` carries it out and owes the queue and the player
/// their consequence.
enum BookFinishMark {
    /// What the provider said about the title before the mark is written.
    enum Fetch: Equatable, Sendable {
        case fresh(duration: Double, currentTime: Double)
        case offline
        case failed
    }

    /// Where the mark goes.
    enum Step: Equatable, Sendable {
        /// A catalogue title: its mark lives on the device, beside every
        /// other local position. The catalogue's provider writes nothing, so
        /// a mark sent there would vanish without a trace.
        case local(position: Double, duration: Double)
        /// A server title the server answered for: the whole record (time,
        /// duration, flag), never the flag alone, or the server decides what
        /// becomes of the time. A failed send is queued.
        case send(currentTime: Double, duration: Double)
        /// The server cannot be reached: the decision is queued with the
        /// values known here, so it is not lost.
        case queue(currentTime: Double, duration: Double)
        /// The server answered with a fault: nothing is written, and the
        /// reason is shown or logged.
        case refuse
    }

    /// `knownDuration` and `knownFraction` are what the device knows when
    /// the server does not answer; for a catalogue title the duration is
    /// its only source.
    nonisolated static func step(isCatalog: Bool, target: Bool, fetch: Fetch,
                                 knownDuration: Double, knownFraction: Double) -> Step {
        if isCatalog {
            return .local(position: target ? max(knownDuration, 1) : 0, duration: knownDuration)
        }
        switch fetch {
        case .fresh(let duration, let currentTime):
            return .send(currentTime: target ? duration : currentTime, duration: duration)
        case .offline:
            return .queue(currentTime: target ? knownDuration : knownFraction * knownDuration,
                          duration: knownDuration)
        case .failed:
            return .refuse
        }
    }

    struct Outcome {
        let step: Step
        /// The sentence for the person when the mark was refused.
        let reason: String?
    }

    /// Writes the mark where `step` says. Every way that records it drops a
    /// finished title from Up Next and ends it like a natural end when it is
    /// the running one (a no-op otherwise); a refused mark does neither.
    @MainActor
    static func apply(_ entry: LibraryEntry, target: Bool, progress: BookProgress?,
                      provider: any AudioProvider, coordinator: PlayerCoordinator,
                      libraryViewModel: LibraryViewModel?) async -> Outcome {
        let isCatalog = FreeCatalog.isCatalogId(entry.id)
        var fetch = Fetch.failed
        var reason: String?
        if !isCatalog {
            // A fresh state instead of the possibly stale one on screen.
            do {
                let fresh = try await provider.fetchItemDetail(itemId: entry.id)
                fetch = .fresh(duration: fresh.media.duration ?? 0,
                               currentTime: fresh.userMediaProgress?.currentTime ?? 0)
            } catch {
                fetch = NetworkStatus.isOfflineError(error) ? .offline : .failed
                if fetch == .failed {
                    reason = ErrorSentence.of(error)
                    Logger.library.error("BOOK finish mark refused reason=\(FailureReason.of(error), privacy: .public)")
                }
            }
        }
        let duration = entry.item.media?.duration ?? (isCatalog ? progress?.currentTime : nil) ?? 0
        let step = step(isCatalog: isCatalog, target: target, fetch: fetch,
                        knownDuration: duration, knownFraction: progress?.fraction ?? 0)
        if step != .refuse, target { PlayQueue.shared.markedPlayed(entry.id) }
        switch step {
        case .local(let position, let duration):
            ListeningStore.store(entry.id, entry: ProgressMark.entry(
                position: position, duration: duration, nowMs: Date().timeIntervalSince1970 * 1000))
        case .send(let currentTime, let duration):
            do {
                try await provider.updateProgress(itemId: entry.id, currentTime: currentTime,
                                                  duration: duration, isFinished: target)
            } catch {
                await SyncQueue.shared.enqueue(itemId: entry.id, currentTime: currentTime,
                                               duration: duration, isFinished: target)
            }
            libraryViewModel?.noteLocalProgress(itemId: entry.id, currentTime: currentTime,
                                                duration: duration, isFinished: target)
        case .queue(let currentTime, let duration):
            await SyncQueue.shared.enqueue(itemId: entry.id, currentTime: currentTime,
                                           duration: duration, isFinished: target)
            libraryViewModel?.noteLocalProgress(itemId: entry.id, currentTime: currentTime,
                                                duration: duration, isFinished: target)
        case .refuse:
            return Outcome(step: step, reason: reason)
        }
        // The list shows the mark at once, from what it already holds and
        // without the network: a catalogue mark is read from the device, a
        // server mark was just noted. The server's own answer follows when
        // it can be asked; offline that refresh gives up and the list stands.
        await libraryViewModel?.refreshContinueRows()
        if case .send = step { await libraryViewModel?.refreshProgress() }
        if target { coordinator.markPlayedAndAdvance(itemId: entry.id) }
        return Outcome(step: step, reason: nil)
    }
}
