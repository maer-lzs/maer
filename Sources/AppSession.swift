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

    /// Alle aktiven Quellen — für die aggregierte Bibliothek.
    var allProviders: [any AudioProvider] { [provider, localProvider] }

    /// Routet ein Item auf seine Quelle: `local:`-IDs → lokale Dateien,
    /// alles andere → Server. So weiß der Player/Coordinator, wen er fragt.
    func provider(for itemId: String) -> any AudioProvider {
        itemId.hasPrefix("local:") ? localProvider : provider
    }

    private(set) lazy var libraryViewModel = LibraryViewModel(provider: provider)
    private(set) lazy var playerCoordinator = PlayerCoordinator(provider: provider)

    private init() {}
}
