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
    /// updated IN PLACE on login, so the lazy objects below stay valid.
    let authViewModel = AuthViewModel()

    var apiClient: APIClient { authViewModel.apiClient }

    private(set) lazy var libraryViewModel = LibraryViewModel(apiClient: apiClient)
    private(set) lazy var playerCoordinator = PlayerCoordinator(apiClient: apiClient)

    private init() {}
}
