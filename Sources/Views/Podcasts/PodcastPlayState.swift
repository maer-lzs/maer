// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
// `@preconcurrency`: Combine's `ObservableObjectPublisher` is not `Sendable`;
// the explicit `nonisolated let objectWillChange` (needed because the project's
// MainActor default breaks @Published synthesis) would otherwise warn. Apple
// framework, so the pre-concurrency import is the sanctioned suppression.
@preconcurrency import Combine

/// Reactive access to the local podcast progress. Needed because
/// `localPosition` lives in UserDefaults (no @Published). Without this store a
/// "mark as played" would not update the list immediately.
@MainActor
final class PodcastProgressStore: ObservableObject {
    static let shared = PodcastProgressStore()
    // Explicit publisher instead of @Published: under the project default
    // `MainActor` the synthesized ObservableObject conformance from a @Published
    // property fails. We send the change ourselves.
    nonisolated let objectWillChange = ObservableObjectPublisher()
    /// Counts progress changes. Used as a `.task` id to recompute the podcast
    /// sections deliberately (instead of on every body eval).
    private(set) var changeToken = 0

    /// A changed "counts as played" tail (here or adopted from another
    /// device) changes every derived state without a new mark.
    private var tailObserver: NSObjectProtocol?

    private init() {
        tailObserver = NotificationCenter.default.addObserver(
            forName: PlayedTail.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
    }

    func state(for item: LibraryItem) -> EpisodePlayState {
        state(guid: item.id, duration: item.media?.duration ?? 0)
    }

    /// Position marker meaning "played" for episodes WITHOUT a known duration
    /// (feeds without itunes:duration). 30 days in seconds. Far beyond any real
    /// episode/audiobook, and small enough for the Int conversions in the
    /// gpodder push. Without it, "mark as played" was a silent no-op for
    /// duration-less episodes (state() could never reach `time >= duration - 1`).
    /// One truth, in `ProgressMark`. This is only the familiar name.
    nonisolated static var playedSentinel: Double { ProgressMark.playedSentinel }

    /// State directly from guid + duration. Without building a `LibraryItem`
    /// (so the podcast sections compute over thousands of episodes without overhead).
    /// `tail` nil is the person's own; 0 asks for the true end.
    func state(guid: String, duration: Double, tail: Double? = nil) -> EpisodePlayState {
        let stored = ListeningStore.backup(guid)
        return ProgressMark.state(stored: stored, currentDuration: duration,
                                  tail: tail ?? PlayedTail.seconds(forItemId: guid))
    }

    /// "Played" writes the position to the end; "unplayed" writes a `[0, now]`
    /// tombstone instead of deleting the key. A deleted key loses against the
    /// old iCloud value on the next reconcile (newest-timestamp merge) and the
    /// episode would flip back to played. The fresh zero wins and propagates.
    /// Returns the entry it wrote, so a caller that books the change
    /// elsewhere does not read it straight back (a read right after a write
    /// is the expensive one on a large defaults domain).
    @discardableResult
    func setPlayed(_ item: LibraryItem, _ played: Bool) -> [Double] {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let entry: [Double]
        if played {
            // With a known duration write the real end; without one the sentinel.
            // Previously the else branch wrote the UNPLAYED tombstone for
            // duration-less episodes, making "mark as played" a silent no-op.
            // The duration travels along as the THIRD value: it is the
            // reference the check uses later (outward, the real end position
            // still goes out unchanged).
            // The freshest KNOWN length: after a playback the player has
            // written the real asset length into the store, while the passed
            // item may still carry the feed's claim.
            let duration = PodcastSubscriptions.shared.episodeDuration(guid: item.id)
                ?? item.media?.duration ?? 0
            let position = duration > 0 ? duration : Self.playedSentinel
            entry = ProgressMark.entry(position: position, duration: duration, nowMs: nowMs)
        } else {
            // The unplayed tombstone goes through the one entry builder too.
            // The fence's proof run flushed this literal out as the second
            // writer its line-window predecessor had missed.
            entry = ProgressMark.entry(position: 0, duration: 0, nowMs: nowMs)
        }
        ListeningStore.store(item.id, entry: entry)
        changeToken += 1
        objectWillChange.send()
        ListeningRevision.shared.bump("podcast mark")
        return entry
    }

    /// After an external write of `localPosition` (e.g. Apple import), have all
    /// observing rows re-evaluate. Every caller is an EVENT (finish, cloud or
    /// server adoption, import), so the listening revision moves with it.
    func reload() {
        changeToken += 1
        objectWillChange.send()
        ListeningRevision.shared.bump("podcast store reload")
    }
}

/// Played state unified (reconciliation): `localPosition` already mirrors
/// local+iCloud (after `PodcastCloudSync.reconcile`); for `abspod:` also include
/// the ABS server state. The newer timestamp wins.
@MainActor
func podcastPlayState(for item: LibraryItem, tail: Double? = nil) -> EpisodePlayState {
    let duration = item.media?.duration ?? 0
    // Equivalent ids of both sources (self + bridge via the feed guid) so the
    // imported rss: history is visible on the ABS copy too.
    let ids = ABSPodcastProvider.shared.equivalentIds(item.id)

    // Newest local state across all bridge ids.
    var bestGuid: String?
    var bestTs = -1.0
    for id in ids {
        if let arr = ListeningStore.backup(id),
           arr.count >= 2, arr[1] > bestTs {
            bestTs = arr[1]; bestGuid = id
        }
    }

    // Include the server state of the abspod: copy (newer timestamp wins).
    if let absId = ids.first(where: ItemNamespace.isABSPodcast) {
        let absTs = ABSPodcastProvider.shared.episodeProgress[absId]?.lastUpdate ?? -1
        if absTs > bestTs {
            return ABSPodcastProvider.shared.state(forEpisodeId: absId, duration: duration, tail: tail)
        }
    }
    guard let bestGuid else { return .unplayed }
    return PodcastProgressStore.shared.state(guid: bestGuid, duration: duration, tail: tail)
}

/// Does a deliberate Play on this episode start from the beginning? Only at
/// the TRUE end (or the server's finished flag), the same question
/// `PlayerCoordinator.isFinishedAtOpen` asks. The played state a row SHOWS
/// counts the person's tail as well, and asking that here restarted an
/// episode a minute before its end at 0 and sent the 0 to every device.
/// Within the tail a Play resumes where the episode stands.
@MainActor
func podcastRestartsOnPlay(_ item: LibraryItem) -> Bool {
    podcastPlayState(for: item, tail: 0) == .played
}

/// "Mark played/unplayed": always set locally (→ iCloud propagates it) and for
/// ABS additionally on the server; then push to iCloud immediately.
/// - Parameter syncCloud: bulk callers (mark all) pass false and run ONE full
///   reconcile afterwards instead of one merge per episode.
/// - Parameter router: where the server copy of the episode is asked for;
///   a witness passes its own.
@MainActor
func podcastSetPlayed(_ item: LibraryItem, _ played: Bool, syncCloud: Bool = true,
                      router: ItemRouter = .live) {
    let written = PodcastProgressStore.shared.setPlayed(item, played)
    // Listen log (show-independent history): played → upsert via the ONE
    // threshold evaluation; unplayed → tombstone (survives reconciles).
    if played {
        PodcastListenLog.shared.noteIfPlayed(
            guid: item.id, duration: item.media?.duration ?? 0,
            episodeTitle: item.title, showTitle: item.author ?? "",
            feedURL: PodcastSubscriptions.shared.feedURL(forEpisodeId: item.id) ?? "",
            written: written)
    } else {
        PodcastListenLog.shared.markUnplayed(guid: item.id)
    }
    // Invariant "heard = flies out": marking an episode played drops it (and its
    // rss/abspod twin) from the global Up-Next queue. Covers the episode menu,
    // swipe action, detail page and "mark all". They all route through here.
    if played { PlayQueue.shared.markedPlayed(item.id) }
    // GT 09.08.: … and the SAME place owes the player its consequence. The
    // queue invariant was carried everywhere, the player one was not. So
    // marking the RUNNING episode as heard left it playing (X16c decided the
    // rule long ago: mark = as if it had ended, stop + auto-continue).
    // `markPlayedAndAdvance` is a no-op for a non-active item, so this stays
    // one line instead of a condition at every surface.
    if played { AppSession.shared.playerCoordinator.markPlayedAndAdvance(itemId: item.id) }
    // Mirror on the server too: the abspod: copy is self (abspod item) or the
    // server episode bridged via the feed guid (rss item).
    let absId = ItemNamespace.isABSPodcast(item.id)
        ? item.id
        : ABSPodcastProvider.shared.bridgedABSId(forRSS: item.id)
    if let absId, let absItem = router.item(absId) {
        Task { await ABSPodcastProvider.shared.setPlayed(absItem, played) }
    }
    // Targeted single-id merge. The full reconcile enumerates ALL UserDefaults
    // keys and is far too expensive per episode (see bulk callers).
    if syncCloud { PodcastCloudSync.shared.reconcile(changedId: item.id) }
}

// MARK: - Shared helpers
