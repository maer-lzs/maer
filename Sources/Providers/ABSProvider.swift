import Foundation

/// Audiobookshelf als erster AudioProvider. Die Konformität ist bewusst
/// fast leer: das Protokoll wurde entlang der bestehenden APIClient-
/// Oberfläche geschnitten. Ein eigener Wrapper-Typ kommt erst, wenn ein
/// zweiter Provider echte Konflikte aufzeigt.
extension APIClient: AudioProvider {
    var providerId: String { "abs" }

    var capabilities: ProviderCapabilities {
        [.progressSync, .bookmarks, .passwordLogin]
    }

    var streamAuthHeaders: [String: String] {
        guard let token, !token.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }
}
