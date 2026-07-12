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
    /// Inhalte müssen für Offline-Nutzung erst HERUNTERGELADEN werden
    /// (Server). Quellen ohne dieses Flag (lokale Dateien) sind per
    /// Definition immer offline verfügbar — der Core zeigt dort keine
    /// Download-Steuerung.
    static let downloadable = ProviderCapabilities(rawValue: 1 << 4)
}

/// Vorgefertigte „Continue"/„Recently Added"-Reihen einer Quelle — damit die
/// oberen Bibliotheks-Reihen sofort vollständig stehen, während die Gesamtliste
/// noch progressiv nachlädt.
struct LibrarySeed {
    var continueListening: [LibraryItem] = []
    var recentlyAdded: [LibraryItem] = []
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
    /// Eine Seite der Bibliothek (Server-Paging). Standard-Implementierung
    /// (siehe Extension) liefert die ganze Liste als eine Seite — nur ABS
    /// paginiert echt; lokale/RSS-Quellen sind ohnehin klein.
    func fetchLibraryItemsPage(libraryId: String, limit: Int, page: Int) async throws
        -> (items: [LibraryItem], total: Int)
    /// Fertige „Continue"/„Recently Added"-Reihen der Quelle (ABS
    /// `personalized`). Standard: leer — nur ABS liefert sie; lokale/RSS-Quellen
    /// leiten diese Reihen aus ihrer (kleinen) Vollliste ab.
    func fetchLibrarySeed(libraryId: String) async throws -> LibrarySeed
    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail

    // MARK: Medien
    func coverURL(forItemId itemId: String) -> URL?
    func streamURL(forContentPath contentPath: String) -> URL?
    /// HTTP-Header für Streaming/Downloads (heute: Bearer-Token); leer,
    /// wenn die Quelle keine Auth braucht (lokale Dateien).
    var streamAuthHeaders: [String: String] { get }

    /// Item-spezifische Streaming/Download-Header. Standard = `streamAuthHeaders`;
    /// RSS überschreibt für private/Premium-Feeds (Basic-Auth je Feed).
    func streamAuthHeaders(forItemId itemId: String) -> [String: String]

    // MARK: Lesezeichen (nur mit `.bookmarks`-Capability aufrufen)
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark]
    func createBookmark(itemId: String, time: Double, title: String) async throws
    func deleteBookmark(itemId: String, time: Double) async throws
}

extension AudioProvider {
    /// Standard: item-unabhängig die Quellen-Header.
    func streamAuthHeaders(forItemId itemId: String) -> [String: String] { streamAuthHeaders }

    /// Standard: kein echtes Server-Paging — die ganze (kleine) Liste als eine
    /// Seite. ABS überschreibt das mit echtem `limit`/`page`.
    func fetchLibraryItemsPage(libraryId: String, limit: Int, page: Int) async throws
        -> (items: [LibraryItem], total: Int) {
        let all = try await fetchLibraryItems(libraryId: libraryId)
        return (all, all.count)
    }

    /// Standard: keine vorgefertigten Reihen — der Aufrufer leitet sie aus der
    /// Vollliste ab. ABS überschreibt das mit der `personalized`-Ansicht.
    func fetchLibrarySeed(libraryId: String) async throws -> LibrarySeed { LibrarySeed() }

    /// Standard: die meisten Quellen liefern Hörbücher.
    var mediaType: MediaType { .audiobooks }
    /// Ob die Quelle aktuell Inhalte hat (steuert die Tab-Sichtbarkeit).
    /// Standard: immer verfügbar; Podcasts z. B. erst mit einem Abo.
    var isAvailable: Bool { true }
}
