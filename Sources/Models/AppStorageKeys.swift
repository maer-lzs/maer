import Foundation

/// Zentrale Stelle für alle UserDefaults-Keys — statt verstreuter String-
/// Literale. Pro-Buch-Keys werden über `cleanupPerBookKeys` entsorgt, sobald
/// das Buch nicht mehr in der (vollständigen) Bibliothek existiert.
// nonisolated: pure key helpers, must be callable from background tasks
// (the project uses default MainActor isolation).
nonisolated enum AppStorageKeys {
    static let skipInterval = "skipInterval"
    /// Speed for books that have no per-book rate saved yet.
    static let defaultPlaybackRate = "defaultPlaybackRate"
    /// Resume slightly earlier after a longer pause (default ON).
    static let smartRewind = "smartRewind"
    /// "system" | "light" | "dark" — overrides the system appearance.
    static let appearance = "appearanceOverride"
    /// Ask before downloading without Wi-Fi (default ON).
    static let warnCellularDownload = "warnCellularDownload"
    /// Library chosen in the settings; empty/unknown → first library.
    static let selectedLibraryId = "selectedLibraryId"
    /// Start the next unfinished book of the series when one ends (default OFF).
    static let autoPlayNextInSeries = "autoPlayNextInSeries"
    /// Bookmark create/delete ops that have not reached the server yet.
    static let pendingBookmarkOps = "pendingBookmarkOps"
    /// Optionaler PodcastIndex-Zugang für die Podcast-Suche (der iTunes-
    /// Katalog braucht keinen Key). Geringe Sensibilität → UserDefaults.
    static let podcastIndexKey = "podcastIndexKey"
    /// Alter UserDefaults-Key des Secrets — nur noch für die einmalige
    /// Migration in den Keychain (s. u.).
    static let podcastIndexSecret = "podcastIndexSecret"

    /// Der API-Key ist ein öffentlicher Bezeichner → UserDefaults reicht.
    static var podcastIndexKeyValue: String {
        get { UserDefaults.standard.string(forKey: podcastIndexKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: podcastIndexKey) }
    }

    /// Das Secret ist ein Credential → Keychain statt Klartext-UserDefaults.
    /// Beim ersten Zugriff wird ein evtl. alter UserDefaults-Wert migriert.
    static var podcastIndexSecretValue: String {
        if let s = KeychainStore.load(forKey: KeychainKey.podcastIndexSecret), !s.isEmpty {
            return s
        }
        let old = UserDefaults.standard.string(forKey: podcastIndexSecret) ?? ""
        if !old.isEmpty {
            KeychainStore.save(old, forKey: KeychainKey.podcastIndexSecret)
            UserDefaults.standard.removeObject(forKey: podcastIndexSecret)
        }
        return old
    }

    static func setPodcastIndexSecret(_ value: String) {
        if value.isEmpty {
            KeychainStore.delete(forKey: KeychainKey.podcastIndexSecret)
        } else {
            KeychainStore.save(value, forKey: KeychainKey.podcastIndexSecret)
        }
        UserDefaults.standard.removeObject(forKey: podcastIndexSecret)
    }

    static var podcastIndexConfigured: Bool {
        !podcastIndexKeyValue.isEmpty && !podcastIndexSecretValue.isEmpty
    }
    /// Podcast-Hörfortschritt über iCloud zwischen den eigenen Geräten syncen.
    static let podcastICloudSync = "podcastICloudSync"
    static var podcastICloudSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: podcastICloudSync) as? Bool ?? true
    }
    static let lastPlayedItemId = "lastPlayedItemId"
    static let pendingDownloadDestinations = "pendingDownloadDestinations"
    static let librarySortOption = "librarySortOption"
    static let libraryFilterOption = "libraryFilterOption"
    static let librarySortAscending = "librarySortAscending"
    static let downloadExtensionRepairDone = "downloadExtensionRepairV2"
    static let downloadDeepValidationDone = "downloadDeepValidationV1"

    static func playbackRate(_ itemId: String) -> String { "playbackRate.\(itemId)" }
    static func localPosition(_ itemId: String) -> String { "localPosition.\(itemId)" }

    /// Pro-Show-Wiedergabetempo (greift als Start-Rate für Folgen dieser Show,
    /// solange keine folgen-eigene Rate gemerkt ist).
    static func podcastShowRate(_ showId: String) -> String { "podcastShowRate.\(showId)" }

    /// Show-ID aus einer Podcast-Folgen-ID ableiten (`rss:<key>:<guid>` →
    /// `rss:<key>`, `abspod:<item>:<ep>` → `abspod:<item>`). Feed-Key/Item-ID
    /// enthalten kein `:`, daher sind die ersten beiden Segmente die Show-ID.
    static func podcastShowId(forEpisodeId id: String) -> String? {
        guard id.hasPrefix("rss:") || id.hasPrefix("abspod:") else { return nil }
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ":")
    }

    /// Entfernt pro-Buch-Einträge zu Büchern, die es nicht mehr gibt.
    /// Nur mit einer VOLLSTÄNDIGEN Bibliotheksliste aufrufen (nie mit der
    /// gefilterten Offline-Liste — sonst fliegen gültige Keys raus).
    static func cleanupPerBookKeys(validItemIds: Set<String>) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys {
            for prefix in ["playbackRate.", "localPosition."] where key.hasPrefix(prefix) {
                let id = String(key.dropFirst(prefix.count))
                // NUR rohe ABS-Buch-IDs bereinigen. Podcast-/Lokale-Keys
                // (`rss:`/`abspod:`/`local:`) gehören anderen Quellen mit eigenem
                // Lebenszyklus — `validItemIds` enthält nur Hörbücher, sonst
                // würden hier ALLE Podcast-/Local-Fortschritte gelöscht.
                if id.hasPrefix("rss:") || id.hasPrefix("abspod:") || id.hasPrefix("local:") {
                    continue
                }
                if !validItemIds.contains(id) {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }
}
