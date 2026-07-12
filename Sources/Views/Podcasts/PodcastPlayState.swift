import SwiftUI
import Combine

/// Drei Zustände einer Episode fürs UI — ungehört, angespielt (mit Restzeit)
/// oder komplett gehört. Podcasts syncen NICHT über den Server; die Basis ist
/// die lokale `localPosition` (die der Player alle 5 s schreibt).
enum EpisodePlayState: Equatable {
    case unplayed
    case inProgress(fraction: Double, remaining: Double)
    case played
}

/// Reaktiver Zugriff auf den lokalen Podcast-Fortschritt. Nötig, weil
/// `localPosition` in UserDefaults liegt (kein @Published) — ohne diesen Store
/// würde ein „als gehört markieren" die Liste nicht sofort aktualisieren.
@MainActor
final class PodcastProgressStore: ObservableObject {
    static let shared = PodcastProgressStore()
    // Expliziter Publisher statt @Published: unter dem Projekt-Default
    // `MainActor` scheitert die synthetisierte ObservableObject-Conformance
    // aus einer @Published-Property. Wir senden die Änderung selbst.
    nonisolated let objectWillChange = ObservableObjectPublisher()
    /// Zählt Fortschritts-Änderungen — als `.task`-id, um die Podcast-Sektionen
    /// gezielt neu zu berechnen (statt bei jedem Body-Eval).
    private(set) var changeToken = 0

    func state(for item: LibraryItem) -> EpisodePlayState {
        state(guid: item.id, duration: item.media?.duration ?? 0)
    }

    /// Zustand direkt aus guid + Dauer — ohne ein `LibraryItem` zu bauen
    /// (die Podcast-Sektionen rechnen so über tausende Folgen ohne Overhead).
    func state(guid: String, duration: Double) -> EpisodePlayState {
        guard duration > 0,
              let stored = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(guid)) as? [Double],
              stored.count == 2 else { return .unplayed }
        let time = stored[0]
        if time >= duration - 1 { return .played }
        if time > 1 { return .inProgress(fraction: min(max(time / duration, 0), 1), remaining: duration - time) }
        return .unplayed
    }

    /// „Als gehört" schreibt die Position ans Ende, „ungehört" löscht sie.
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

    /// Nach externem Schreiben von `localPosition` (z. B. Apple-Import) alle
    /// beobachtenden Zeilen neu bewerten lassen.
    func reload() { changeToken += 1; objectWillChange.send() }
}

/// Gehört-Zustand vereinheitlicht (Reconciliation): `localPosition` spiegelt
/// bereits lokal+iCloud (nach `PodcastCloudSync.reconcile`); für `abspod:`
/// zusätzlich den ABS-Server-Stand einbeziehen — der jüngere Zeitstempel
/// gewinnt.
@MainActor
func podcastPlayState(for item: LibraryItem) -> EpisodePlayState {
    let duration = item.media?.duration ?? 0
    // Gleichwertige IDs beider Quellen (self + Brücke über die Feed-guid), damit
    // die importierte rss:-History auch auf der ABS-Kopie sichtbar ist.
    let ids = ABSPodcastProvider.shared.equivalentIds(item.id)

    // Jüngster lokaler Stand über alle Brücken-IDs.
    var bestGuid: String?
    var bestTs = -1.0
    for id in ids {
        if let arr = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(id)) as? [Double],
           arr.count == 2, arr[1] > bestTs {
            bestTs = arr[1]; bestGuid = id
        }
    }

    // Server-Stand der abspod:-Kopie einbeziehen (jüngerer Zeitstempel gewinnt).
    if let absId = ids.first(where: { $0.hasPrefix("abspod:") }) {
        let absTs = ABSPodcastProvider.shared.episodeProgress[absId]?.lastUpdate ?? -1
        if absTs > bestTs {
            return ABSPodcastProvider.shared.state(forEpisodeId: absId, duration: duration)
        }
    }
    guard let bestGuid else { return .unplayed }
    return PodcastProgressStore.shared.state(guid: bestGuid, duration: duration)
}

/// „Als gehört/ungehört": immer lokal setzen (→ iCloud propagiert es) und bei
/// ABS zusätzlich am Server; danach sofort nach iCloud pushen.
@MainActor
func podcastSetPlayed(_ item: LibraryItem, _ played: Bool) {
    PodcastProgressStore.shared.setPlayed(item, played)
    // Auch am Server spiegeln: die abspod:-Kopie ist self (abspod-Item) oder die
    // über die Feed-guid gebrückte Server-Folge (rss-Item).
    let absId = item.id.hasPrefix("abspod:")
        ? item.id
        : ABSPodcastProvider.shared.bridgedABSId(forRSS: item.id)
    if let absId, let absItem = AppSession.shared.libraryItem(forId: absId) {
        Task { await ABSPodcastProvider.shared.setPlayed(absItem, played) }
    }
    PodcastCloudSync.shared.reconcile()
}

// MARK: - Gemeinsame Helfer
