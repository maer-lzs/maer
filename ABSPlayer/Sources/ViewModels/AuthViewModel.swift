import Foundation
import Combine

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var serverURLString: String
    @Published var apiToken: String = ""
    @Published var isLoggedIn: Bool
    @Published var isLoading = false
    @Published var errorMessage: String?

    let apiClient: APIClient

    init() {
        let storedURLString = KeychainStore.load(forKey: KeychainKey.serverURL) ?? ""
        let storedToken = KeychainStore.load(forKey: KeychainKey.apiToken)

        self.serverURLString = storedURLString
        let url = Self.normalizedURL(from: storedURLString) ?? URL(string: "https://example.invalid")!
        self.apiClient = APIClient(baseURL: url, token: storedToken)
        self.isLoggedIn = (storedToken?.isEmpty == false) && !storedURLString.isEmpty

        // Läuft der Token ab (401), automatisch zurück zum Setup-Screen.
        apiClient.onUnauthorized = { [weak self] in
            guard let self, self.isLoggedIn else { return }
            self.errorMessage = "Der Token wurde vom Server abgelehnt. Bitte neu verbinden."
            self.logout()
        }
    }

    /// Prüft Server-URL + Token, indem einmal die Bibliotheken abgerufen werden.
    /// Bewusst kein separater Login-Call — der Token wird direkt in der
    /// Audiobookshelf-Weboberfläche erzeugt (siehe README).
    func connect() async {
        errorMessage = nil
        guard let url = Self.normalizedURL(from: serverURLString) else {
            errorMessage = "Bitte eine gültige Server-Adresse eingeben, z. B. https://audio.example.de"
            return
        }
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            errorMessage = "Bitte einen API-Token eintragen."
            return
        }

        isLoading = true
        defer { isLoading = false }

        apiClient.updateBaseURL(url)
        apiClient.updateToken(trimmedToken)

        do {
            _ = try await apiClient.fetchLibraries()
            KeychainStore.save(url.absoluteString, forKey: KeychainKey.serverURL)
            KeychainStore.save(trimmedToken, forKey: KeychainKey.apiToken)
            apiToken = ""
            isLoggedIn = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func logout() {
        KeychainStore.delete(forKey: KeychainKey.apiToken)
        isLoggedIn = false
    }

    private static func normalizedURL(from raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        return URL(string: trimmed)
    }
}
