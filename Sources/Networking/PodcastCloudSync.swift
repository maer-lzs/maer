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

    /// Guard against double observer registration (start() can run again when
    /// the library view is recreated, e.g. logout→login) — a second observer
    /// would double every reconcile on external iCloud changes.
    private var didStart = false

    /// Call once at app start: listen for iCloud changes + reconcile immediately.
    func start() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        guard !didStart else { reconcile(); return }
        didStart = true
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

        // Collect local positions.
        var local: [String: [Double]] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard podcastPrefixes.contains(where: { key.hasPrefix($0) }),
                  let arr = Self.coerce(value), arr.count == 2 else { continue }
            local[String(key.dropFirst(keyPrefix.count))] = arr
        }

        // iCloud blob (coerce defensively — KV store returns NSNumber arrays).
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
                defaults.set(c, forKey: keyPrefix + id)   // iCloud newer → local
                localChanged = true
            } else if lts > cts, let l = local[id] {
                cloud[id] = l                              // local newer → iCloud
                cloudChangedFlag = true
            }
        }

        if cloudChangedFlag {
            store.set(cloud, forKey: blobKey)
            store.synchronize()
        }
        if localChanged {
            // Have the UI/sections and ABS provider display re-evaluate.
            PodcastProgressStore.shared.reload()
        }
    }

    /// Targeted single-episode merge — for the frequent per-write callers
    /// (mark played/unplayed, position saves). The full `reconcile()` enumerates
    /// the ENTIRE UserDefaults per call, which is far too expensive to run per
    /// episode (mark-all on a 200-episode show = 200 full scans).
    func reconcile(changedId id: String) {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        guard id.hasPrefix("rss:") || id.hasPrefix("abspod:") else { return }
        let defaults = UserDefaults.standard
        var cloud: [String: Any] = store.dictionary(forKey: blobKey) ?? [:]

        let localArr = defaults.array(forKey: keyPrefix + id).flatMap { Self.coerce($0) }
        let cloudArr = cloud[id].flatMap { Self.coerce($0) }
        let lts = (localArr?.count == 2) ? localArr![1] : -1
        let cts = (cloudArr?.count == 2) ? cloudArr![1] : -1
        if cts > lts, let c = cloudArr {
            defaults.set(c, forKey: keyPrefix + id)
            PodcastProgressStore.shared.reload()
        } else if lts > cts, let l = localArr {
            cloud[id] = l
            store.set(cloud, forKey: blobKey)
            store.synchronize()
        } else if localArr == nil, cloudArr != nil {
            // Local delete (mark unplayed) wins only with a fresh timestamp we
            // don't have — write an explicit zero so other devices follow.
            cloud[id] = [0.0, Date().timeIntervalSince1970 * 1000]
            store.set(cloud, forKey: blobKey)
            store.synchronize()
        }
    }

    /// `[Double]` from a plist value (array of `Double`/`NSNumber`).
    private static func coerce(_ value: Any) -> [Double]? {
        if let d = value as? [Double] { return d }
        if let n = value as? [NSNumber] { return n.map(\.doubleValue) }
        return nil
    }
}
