import Foundation

/// Was eine Audioquelle KANN — die UI blendet Feature-Flächen aus, statt
/// gegen Wände zu laufen (z. B. hat RSS keinen serverseitigen Fortschritt).
struct ProviderCapabilities: OptionSet {
    let rawValue: Int

    /// Hörposition liegt serverseitig und wird abgeglichen (SyncQueue,
    /// Konflikt-Erkennung, Geräte-Wechsel).
    static let progressSync = ProviderCapabilities(rawValue: 1 << 0)
    /// Serverseitige Lesezeichen (Position + Titel).
    static let bookmarks = ProviderCapabilities(rawValue: 1 << 1)
    /// Quelle kann selbst suchen (sonst nur lokale Filterung).
    static let remoteSearch = ProviderCapabilities(rawValue: 1 << 2)
    /// Anmeldung mit Benutzername/Passwort möglich.
    static let passwordLogin = ProviderCapabilities(rawValue: 1 << 3)
}

/// Die eine Schnittstelle, über die der Mär-Core (Player, Downloads, Sync,
/// Suche, CarPlay, Widgets) Audioquellen sieht. Provider liefern NUR Daten —
/// alles andere (Offline, Sleep, Kapitel-Logik, Queue, Statistik) gehört
/// dem Core; der Player weiß nicht, woher ein Titel stammt.
///
/// ID-Konvention: Der Audiobookshelf-HAUPTPROVIDER verwendet rohe Item-IDs
/// (Bestandsdaten: Download-Ordner, UserDefaults-Keys, Cover-Cache hängen
/// daran). Jeder KÜNFTIGE Provider prefixt seine IDs mit "<providerId>:" —
/// z. B. `local:…`, `rss:…` — damit sich Quellen nie in die Quere kommen.
///
/// `ProgressSyncAPI` (fetchAllProgress/updateProgress) ist Teil des
/// Vertrags; Provider ohne `.progressSync`-Capability liefern leere Daten
/// bzw. werfen nicht — der Core fragt vorher die Capability ab.
@MainActor
protocol AudioProvider: AnyObject, ProgressSyncAPI {
    /// Kurzes, stabiles Kürzel ("abs", "local", …) — auch ID-Namespace.
    var providerId: String { get }
    /// Inhaltstyp (Tab) dieser Quelle — Standard: Hörbücher.
    var mediaType: MediaType { get }
    var capabilities: ProviderCapabilities { get }

    // MARK: Bibliothek
    func fetchLibraries() async throws -> [ABSLibrary]
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem]
    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail

    // MARK: Medien
    func coverURL(forItemId itemId: String) -> URL?
    func streamURL(forContentPath contentPath: String) -> URL?
    /// HTTP-Header für Streaming/Downloads (heute: Bearer-Token); leer,
    /// wenn die Quelle keine Auth braucht (lokale Dateien).
    var streamAuthHeaders: [String: String] { get }

    // MARK: Lesezeichen (nur mit `.bookmarks`-Capability aufrufen)
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark]
    func createBookmark(itemId: String, time: Double, title: String) async throws
    func deleteBookmark(itemId: String, time: Double) async throws
}

extension AudioProvider {
    /// Standard: die meisten Quellen liefern Hörbücher.
    var mediaType: MediaType { .audiobooks }
}
