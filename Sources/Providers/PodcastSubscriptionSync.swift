import Foundation

/// Gleicht lokale RSS-Abos mit dem Audiobookshelf-Server ab. ABS ist die
/// kanonische, geräteübergreifend synchronisierende Quelle: jeder lokal
/// abonnierte Feed, der noch nicht am Server liegt, wird dort angelegt; ein
/// archivierter Server-Eintrag wird reaktiviert statt neu erzeugt. Nichts wird
/// gelöscht (Abbestellen = Archivieren, Server-Historie bleibt). Über die
/// Feed-URL-Dedup in `allShows` zeigt die App danach jeden Feed nur einmal
/// (ABS bevorzugt) — RSS bleibt als Offline-/Fallback-Quelle im Hintergrund.
@MainActor
enum PodcastSubscriptionSync {
    struct Report: Equatable {
        var pushed = 0          // neu am Server angelegt
        var reactivated = 0     // archivierten Server-Eintrag wieder aktiviert
        var alreadySynced = 0   // war schon am Server
        var failed: [String] = []

        var isEmpty: Bool {
            pushed == 0 && reactivated == 0 && alreadySynced == 0 && failed.isEmpty
        }
    }

    /// Läuft der Auto-Abgleich schon/lief er in dieser Session? Verhindert, dass
    /// jeder Tab-Wechsel erneut den Server abfragt.
    private static var didAutoReconcile = false
    private static var isRunning = false

    /// Lokale RSS-Abos auf den Server spiegeln. Idempotent — mehrfaches Aufrufen
    /// legt nichts doppelt an. Läuft nie zwei Durchläufe gleichzeitig.
    @discardableResult
    static func reconcile() async -> Report {
        var report = Report()
        guard !isRunning else { return report }
        isRunning = true
        defer { isRunning = false }

        let abs = ABSPodcastProvider.shared
        // Ohne Server-Podcast-Bibliothek gibt es kein Ziel zum Spiegeln.
        guard abs.hasPodcasts else { return report }
        // Erst den echten Server-Stand laden, sonst legen wir evtl. Dubletten an.
        await abs.refresh()

        // Server-Feeds (aktiv + archiviert) normalisiert indexieren.
        var serverByURL: [String: PodcastShow] = [:]
        for show in abs.shows where !show.feedURL.isEmpty {
            serverByURL[PodcastSubscriptions.normalizeFeedURL(show.feedURL)] = show
        }

        // Lokale Abos intern dedupen (gleiche normalisierte URL nur einmal).
        var seen = Set<String>()
        for show in PodcastSubscriptions.shared.shows where !show.feedURL.isEmpty {
            let norm = PodcastSubscriptions.normalizeFeedURL(show.feedURL)
            guard seen.insert(norm).inserted else { continue }

            if let existing = serverByURL[norm] {
                if abs.archivedShowIds.contains(existing.id) {
                    abs.setArchived(existing.id, false)
                    report.reactivated += 1
                } else {
                    report.alreadySynced += 1
                }
                continue
            }
            if let error = await abs.subscribeOnServer(feedURL: show.feedURL) {
                report.failed.append("\(show.title): \(error)")
            } else {
                report.pushed += 1
            }
        }
        return report
    }

    /// Einmal pro App-Session automatisch abgleichen, sobald ein ABS-Podcast-
    /// Server erreichbar ist und es überhaupt lokale Abos zu spiegeln gibt.
    static func autoReconcileIfNeeded() async {
        guard !didAutoReconcile,
              ABSPodcastProvider.shared.hasPodcasts,
              !PodcastSubscriptions.shared.shows.isEmpty else { return }
        didAutoReconcile = true
        await reconcile()
    }
}
