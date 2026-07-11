import Foundation

/// Zweiter AudioProvider: importierte lokale Dateien (kein Server). Beweist
/// die Provider-Abstraktion mit einer Quelle, die weder Login, Netz noch
/// serverseitigen Fortschritt kennt — Fortschritt läuft rein lokal über den
/// bestehenden `localPosition`-Mechanismus.
@MainActor
final class LocalProvider: AudioProvider {
    static let shared = LocalProvider()
    private let library = LocalLibrary.shared

    private init() {}

    var providerId: String { "local" }
    /// Keine Capability: keine Server-Sync, keine Server-Lesezeichen,
    /// keine Remote-Suche, kein Passwort-Login.
    var capabilities: ProviderCapabilities { [] }
    var streamAuthHeaders: [String: String] { [:] }

    func fetchLibraries() async throws -> [ABSLibrary] {
        [ABSLibrary(id: "local", name: String(localized: "Local Files"))]
    }

    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        library.libraryItems()
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        guard let detail = library.itemDetail(id: itemId) else {
            throw NSError(domain: "LocalProvider", code: 404)
        }
        return detail
    }

    func coverURL(forItemId itemId: String) -> URL? {
        library.coverURL(forItemId: itemId)
    }

    func streamURL(forContentPath contentPath: String) -> URL? {
        library.fileURL(forContentPath: contentPath)
    }

    /// Fortschritt kommt rein lokal aus `localPosition` — der Provider ist
    /// die EINZIGE Schnittstelle nach draußen, der Core liest nie selbst.
    func fetchAllProgress() async throws -> [String: BookProgress] {
        var map: [String: BookProgress] = [:]
        for item in library.libraryItems() {
            guard let duration = item.media?.duration, duration > 0,
                  let stored = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(item.id)) as? [Double],
                  stored.count == 2 else { continue }
            let time = stored[0]
            map[item.id] = BookProgress(
                fraction: min(max(time / duration, 0), 1),
                isFinished: time >= duration - 1,
                lastUpdate: stored[1],
                currentTime: time
            )
        }
        return map
    }

    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}

    // Keine Server-Lesezeichen (Capability fehlt — wird nie aufgerufen).
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}
}
