import Foundation

/// Prozessweite Wiedergabe-/Bibliotheks-Session. Bisher lebten Coordinator
/// und LibraryViewModel als @StateObject in der LibraryView — bei einem
/// CarPlay-KALTSTART (App wird nur für die Auto-Szene geweckt, keine UI)
/// existierten sie damit gar nicht. Hier gehören sie dem Prozess; UI und
/// CarPlay-Szene teilen sich dieselben Instanzen (ein Player, eine Queue).
@MainActor
final class AppSession {
    static let shared = AppSession()

    /// Owns the APIClient (built from the keychain) — base URL and token are
    /// updated IN PLACE on login, so the objects below stay valid.
    let authViewModel = AuthViewModel()

    /// Der Server-Provider (Audiobookshelf) — Basis für Login, Bibliotheks-
    /// Auswahl, Settings. `apiClient` bleibt für die ABS-spezifische Anmeldung.
    var provider: any AudioProvider { authViewModel.apiClient }
    var apiClient: APIClient { authViewModel.apiClient }

    /// Lokale Dateien als zweite Quelle (immer vorhanden, kein Login).
    var localProvider: LocalProvider { LocalProvider.shared }

    /// Podcasts (RSS-Feeds) als Quelle vom Typ `.podcasts`.
    var rssProvider: RSSProvider { RSSProvider.shared }

    /// Alle aktiven Quellen.
    var allProviders: [any AudioProvider] { [provider, localProvider, rssProvider] }

    /// Routet ein Item auf seine Quelle anhand des ID-Präfix. Das ist die
    /// EINZIGE Stelle, die ID-Namespaces kennen darf (der Router).
    func provider(for itemId: String) -> any AudioProvider {
        if itemId.hasPrefix("local:") { return localProvider }
        if itemId.hasPrefix("rss:") { return rssProvider }
        return provider
    }

    /// Cover-URL eines beliebigen Items über SEINE Quelle — Views dürfen nie
    /// einen festen Provider annehmen (sonst falsches/kein Cover für lokale
    /// Dateien und Podcast-Episoden).
    func coverURL(forItemId itemId: String) -> URL? {
        provider(for: itemId).coverURL(forItemId: itemId)
    }

    private(set) lazy var libraryViewModel = LibraryViewModel(provider: provider)
    private(set) lazy var playerCoordinator = PlayerCoordinator(provider: provider)

    private init() {}
}
