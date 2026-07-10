import Foundation

/// Zentrale Stelle für alle UserDefaults-Keys — statt verstreuter String-
/// Literale. Pro-Buch-Keys werden über `cleanupPerBookKeys` entsorgt, sobald
/// das Buch nicht mehr in der (vollständigen) Bibliothek existiert.
// nonisolated: pure key helpers, must be callable from background tasks
// (the project uses default MainActor isolation).
nonisolated enum AppStorageKeys {
    static let skipInterval = "skipInterval"
    static let lastPlayedItemId = "lastPlayedItemId"
    static let pendingDownloadDestinations = "pendingDownloadDestinations"
    static let librarySortOption = "librarySortOption"
    static let libraryFilterOption = "libraryFilterOption"
    static let librarySortAscending = "librarySortAscending"
    static let downloadExtensionRepairDone = "downloadExtensionRepairV2"
    static let downloadDeepValidationDone = "downloadDeepValidationV1"

    static func playbackRate(_ itemId: String) -> String { "playbackRate.\(itemId)" }
    static func localPosition(_ itemId: String) -> String { "localPosition.\(itemId)" }

    /// Entfernt pro-Buch-Einträge zu Büchern, die es nicht mehr gibt.
    /// Nur mit einer VOLLSTÄNDIGEN Bibliotheksliste aufrufen (nie mit der
    /// gefilterten Offline-Liste — sonst fliegen gültige Keys raus).
    static func cleanupPerBookKeys(validItemIds: Set<String>) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys {
            for prefix in ["playbackRate.", "localPosition."] where key.hasPrefix(prefix) {
                let id = String(key.dropFirst(prefix.count))
                if !validItemIds.contains(id) {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }
}
