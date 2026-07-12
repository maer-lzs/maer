import Foundation

/// Syncs podcast progress (`localPosition`) across your own Apple devices via
/// iCloud — so "continue on the iPad" works without an ABS server too (and in
/// addition to it).
///
/// Storage: ONE consolidated `NSUbiquitousKeyValueStore` key holding a dict
/// `id → [position, updatedAtMs]` for ALL podcast ids (`rss:` + `abspod:`).
/// One key instead of thousands avoids the KV store's 1024-key limit.
///
/// Merge rule: per episode the newer `updatedAtMs` wins; the winner is written
/// back to the stale side (local OR iCloud). No ping-pong, because writes only
/// happen on a real timestamp lag.
///
/// Without the iCloud KV capability enabled the store stays silent — then
/// everything runs purely locally as before (no crash, no data loss).
@MainActor
final class PodcastCloudSync {
    static let shared = PodcastCloudSync()

    private let store = NSUbiquitousKeyValueStore.default
    private let blobKey = "podcastProgress"
    /// Sync only podcast positions — audiobook/local positions go via the
    /// server or are device-internal.
    private let podcastPrefixes = ["localPosition.rss:", "localPosition.abspod:"]
    private let keyPrefix = "localPosition."

    private init() {}

    /// Call once at app start: listen for iCloud changes + reconcile immediately.
    func start() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
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

    /// Merge local podcast positions and the iCloud blob (newest-wins) and bring
    /// both sides to the shared state.
    func reconcile() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
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
