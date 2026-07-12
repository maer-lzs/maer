import SwiftUI
import Combine

/// Three states of an episode for the UI — unplayed, in progress (with remaining
/// time) or fully played. Podcasts do NOT sync via the server; the basis is the
/// local `localPosition` (which the player writes every 5 s).
enum EpisodePlayState: Equatable {
    case unplayed
    case inProgress(fraction: Double, remaining: Double)
    case played
}

/// Reactive access to the local podcast progress. Needed because
/// `localPosition` lives in UserDefaults (no @Published) — without this store a
/// "mark as played" would not update the list immediately.
@MainActor
final class PodcastProgressStore: ObservableObject {
    static let shared = PodcastProgressStore()
    // Explicit publisher instead of @Published: under the project default
    // `MainActor` the synthesized ObservableObject conformance from a @Published
    // property fails. We send the change ourselves.
    nonisolated let objectWillChange = ObservableObjectPublisher()
    /// Counts progress changes — used as a `.task` id to recompute the podcast
    /// sections deliberately (instead of on every body eval).
    private(set) var changeToken = 0

    func state(for item: LibraryItem) -> EpisodePlayState {
        state(guid: item.id, duration: item.media?.duration ?? 0)
    }

    /// State directly from guid + duration — without building a `LibraryItem`
    /// (so the podcast sections compute over thousands of episodes without overhead).
    func state(guid: String, duration: Double) -> EpisodePlayState {
        guard duration > 0,
              let stored = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(guid)) as? [Double],
              stored.count == 2 else { return .unplayed }
        let time = stored[0]
        if time >= duration - 1 { return .played }
        if time > 1 { return .inProgress(fraction: min(max(time / duration, 0), 1), remaining: duration - time) }
        return .unplayed
    }

    /// "Played" writes the position to the end, "unplayed" deletes it.
    func setPlayed(_ item: LibraryItem, _ played: Bool) {
        let key = AppStorageKeys.localPosition(item.id)
        if played, let duration = item.media?.duration, duration > 0 {
            UserDefaults.standard.set([duration, Date().timeIntervalSince1970 * 1000], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        changeToken += 1
        objectWillChange.send()
    }

    /// After an external write of `localPosition` (e.g. Apple import), have all
    /// observing rows re-evaluate.
    func reload() { changeToken += 1; objectWillChange.send() }
}

/// Played state unified (reconciliation): `localPosition` already mirrors
/// local+iCloud (after `PodcastCloudSync.reconcile`); for `abspod:` also include
/// the ABS server state — the newer timestamp wins.
@MainActor
func podcastPlayState(for item: LibraryItem) -> EpisodePlayState {
    let duration = item.media?.duration ?? 0
    // Equivalent ids of both sources (self + bridge via the feed guid) so the
    // imported rss: history is visible on the ABS copy too.
    let ids = ABSPodcastProvider.shared.equivalentIds(item.id)

    // Newest local state across all bridge ids.
    var bestGuid: String?
    var bestTs = -1.0
    for id in ids {
        if let arr = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(id)) as? [Double],
           arr.count == 2, arr[1] > bestTs {
            bestTs = arr[1]; bestGuid = id
        }
    }

    // Include the server state of the abspod: copy (newer timestamp wins).
    if let absId = ids.first(where: { $0.hasPrefix("abspod:") }) {
        let absTs = ABSPodcastProvider.shared.episodeProgress[absId]?.lastUpdate ?? -1
        if absTs > bestTs {
            return ABSPodcastProvider.shared.state(forEpisodeId: absId, duration: duration)
        }
    }
    guard let bestGuid else { return .unplayed }
    return PodcastProgressStore.shared.state(guid: bestGuid, duration: duration)
}

/// "Mark played/unplayed": always set locally (→ iCloud propagates it) and for
/// ABS additionally on the server; then push to iCloud immediately.
@MainActor
func podcastSetPlayed(_ item: LibraryItem, _ played: Bool) {
    PodcastProgressStore.shared.setPlayed(item, played)
    // Mirror on the server too: the abspod: copy is self (abspod item) or the
    // server episode bridged via the feed guid (rss item).
    let absId = item.id.hasPrefix("abspod:")
        ? item.id
        : ABSPodcastProvider.shared.bridgedABSId(forRSS: item.id)
    if let absId, let absItem = AppSession.shared.libraryItem(forId: absId) {
        Task { await ABSPodcastProvider.shared.setPlayed(absItem, played) }
    }
    PodcastCloudSync.shared.reconcile()
}

// MARK: - Shared helpers
