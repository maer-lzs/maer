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
            self.errorMessage = String(localized: "Session expired — please sign in with a new API token.")
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
                return String(localized: "Server address not found. Please check the address (typo? correct domain?).")
            case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut:
                return String(localized: "Server unreachable. Is Audiobookshelf running, and is the server reachable from this network?")
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
                return String(localized: "No internet connection. Please check your network and try again.")
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
                return String(localized: "Secure connection failed (certificate problem). Is HTTPS set up correctly on the server?")
            default:
                break
            }
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .http(401, _):
                return String(localized: "The server rejected the API token. Please check the token or create a new one.")
            case .decoding:
                return String(localized: "No Audiobookshelf server responds at this address. Please check the address.")
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
            errorMessage = String(localized: "Please enter a valid server address, e.g. https://audio.example.com")
            return
        }
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            errorMessage = String(localized: "Please enter an API token.")
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
