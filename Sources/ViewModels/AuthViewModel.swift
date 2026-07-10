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
            self.errorMessage = "Sitzung abgelaufen — bitte mit einem neuen API-Token anmelden."
            self.logout()
        }
    }

    /// Übersetzt technische Verbindungsfehler in klare, handlungsleitende
    /// Meldungen fürs Onboarding.
    private static func friendlyMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "Server-Adresse nicht gefunden. Bitte die Adresse prüfen (Tippfehler? richtige Domain?)."
            case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut:
                return "Server nicht erreichbar. Läuft Audiobookshelf, und ist der Server aus diesem Netz erreichbar?"
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
                return "Keine Internetverbindung. Bitte Netzwerk prüfen und erneut versuchen."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
                return "Sichere Verbindung fehlgeschlagen (Zertifikatsproblem). Ist HTTPS auf dem Server korrekt eingerichtet?"
            default:
                break
            }
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .http(401, _):
                return "Der Server hat den API-Token abgelehnt. Bitte Token prüfen bzw. einen neuen erzeugen."
            case .decoding:
                return "Unter dieser Adresse antwortet kein Audiobookshelf-Server. Bitte Adresse prüfen."
            default:
                break
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
            errorMessage = Self.friendlyMessage(for: error)
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
