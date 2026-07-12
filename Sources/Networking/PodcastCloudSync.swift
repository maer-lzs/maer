import Foundation

/// Synchronisiert den Podcast-Hörfortschritt (`localPosition`) über iCloud
/// zwischen den eigenen Apple-Geräten — damit „auf dem iPad weiterhören" auch
/// ohne ABS-Server funktioniert (und zusätzlich zu ihm).
///
/// Speicher: EIN konsolidierter `NSUbiquitousKeyValueStore`-Schlüssel mit einem
/// Dict `id → [position, updatedAtMs]` für ALLE Podcast-IDs (`rss:` + `abspod:`).
/// Ein Key statt tausender umgeht das 1024-Keys-Limit des KV-Stores.
///
/// Merge-Regel: pro Episode gewinnt der jüngere `updatedAtMs`; der Gewinner
/// wird auf die veraltete Seite (lokal ODER iCloud) zurückgeschrieben. Kein
/// Ping-Pong, weil nur bei echtem Zeitstempel-Rückstand geschrieben wird.
///
/// Ohne aktivierte iCloud-KV-Capability bleibt der Store stumm — dann läuft
/// alles wie bisher rein lokal (kein Crash, kein Datenverlust).
@MainActor
final class PodcastCloudSync {
    static let shared = PodcastCloudSync()

    private let store = NSUbiquitousKeyValueStore.default
    private let blobKey = "podcastProgress"
    /// Nur Podcast-Positionen syncen — Hörbuch/lokale Positionen laufen über
    /// den Server bzw. sind geräteintern.
    private let podcastPrefixes = ["localPosition.rss:", "localPosition.abspod:"]
    private let keyPrefix = "localPosition."

    private init() {}

    /// Einmalig beim App-Start aufrufen: auf iCloud-Änderungen lauschen + sofort
    /// abgleichen.
    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
        store.synchronize()
        reconcile()
    }

    @objc private nonisolated func cloudChanged() {
        Task { @MainActor in reconcile() }
    }

    /// Lokale Podcast-Positionen und den iCloud-Blob zusammenführen
    /// (newest-wins) und beide Seiten auf den gemeinsamen Stand bringen.
    func reconcile() {
        let defaults = UserDefaults.standard

        // Lokale Positionen einsammeln.
        var local: [String: [Double]] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard podcastPrefixes.contains(where: { key.hasPrefix($0) }),
                  let arr = Self.coerce(value), arr.count == 2 else { continue }
            local[String(key.dropFirst(keyPrefix.count))] = arr
        }

        // iCloud-Blob (defensiv koerzieren — KV-Store liefert NSNumber-Arrays).
        var cloud: [String: [Double]] = [:]
        if let raw = store.dictionary(forKey: blobKey) {
            for (id, value) in raw {
                if let arr = Self.coerce(value), arr.count == 2 { cloud[id] = arr }
            }
        }

        var localChanged = false
        var cloudChangedFlag = false
        for id in Set(local.keys).union(cloud.keys) {
            let lts = local[id]?[1] ?? -1
            let cts = cloud[id]?[1] ?? -1
            if cts > lts, let c = cloud[id] {
                defaults.set(c, forKey: keyPrefix + id)   // iCloud neuer → lokal
                localChanged = true
            } else if lts > cts, let l = local[id] {
                cloud[id] = l                              // lokal neuer → iCloud
                cloudChangedFlag = true
            }
        }

        if cloudChangedFlag {
            store.set(cloud, forKey: blobKey)
            store.synchronize()
        }
        if localChanged {
            // UI/Sektionen und ABS-Provider-Anzeige frisch bewerten lassen.
            PodcastProgressStore.shared.reload()
        }
    }

    /// `[Double]` aus einem plist-Wert (Array aus `Double`/`NSNumber`).
    private static func coerce(_ value: Any) -> [Double]? {
        if let d = value as? [Double] { return d }
        if let n = value as? [NSNumber] { return n.map(\.doubleValue) }
        return nil
    }
}
