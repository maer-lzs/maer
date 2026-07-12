import Foundation

/// Second AudioProvider: imported local files (no server). Proves the provider
/// abstraction with a source that knows neither login, network nor server-side
/// progress — progress runs purely locally via the existing `localPosition`
/// mechanism.
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

    /// Progress comes purely locally from `localPosition` — the provider is the
    /// ONLY interface to the outside, the core never reads it itself.
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
