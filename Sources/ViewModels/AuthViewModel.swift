import Foundation
import Combine

@MainActor
final class AuthViewModel: ObservableObject {
    enum LoginMode: Hashable {
        case password
        case token
    }

    @Published var serverURLString: String
    @Published var loginMode: LoginMode = .password
    @Published var username: String = ""
    @Published var password: String = ""
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

        // If the token expires (401), automatically go back to the setup screen.
        apiClient.onUnauthorized = { [weak self] in
            guard let self, self.isLoggedIn else { return }
            self.errorMessage = String(localized: "Session expired — please sign in again.")
            self.logout()
        }
    }

    /// Translates technical connection errors into clear, actionable messages
    /// for onboarding.
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

    /// Connects via username/password (POST /login → token) OR with a directly
    /// entered API token; the connection is then verified via a library fetch
    /// and the token stored in the keychain.
    func connect() async {
        errorMessage = nil
        guard let url = Self.normalizedURL(from: serverURLString) else {
            errorMessage = String(localized: "Please enter a valid server address, e.g. https://audio.example.com")
            return
        }

        isLoading = true
        defer { isLoading = false }
        apiClient.updateBaseURL(url)

        let token: String
        switch loginMode {
        case .password:
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty, !password.isEmpty else {
                errorMessage = String(localized: "Please enter username and password.")
                return
            }
            do {
                token = try await apiClient.login(username: user, password: password)
            } catch APIError.http(401, _) {
                errorMessage = String(localized: "Login failed — please check username and password.")
                return
            } catch {
                errorMessage = Self.friendlyMessage(for: error)
                return
            }
        case .token:
            let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedToken.isEmpty else {
                errorMessage = String(localized: "Please enter an API token.")
                return
            }
            token = trimmedToken
        }

        apiClient.updateToken(token)
        do {
            _ = try await apiClient.fetchLibraries()
            KeychainStore.save(url.absoluteString, forKey: KeychainKey.serverURL)
            KeychainStore.save(token, forKey: KeychainKey.apiToken)
            apiToken = ""
            password = ""
            isLoggedIn = true
            // Y37/F10: the book tab appears live once the source exists.
            AppSession.shared.notifySourcesChanged()
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
        }
    }

    func logout() {
        KeychainStore.delete(forKey: KeychainKey.apiToken)
        // F10: empty the client too — `isAvailable` (tab visibility, search
        // fan-out) must flip with the logout, not only the root switch.
        apiClient.clearToken()
        isLoggedIn = false
        AppSession.shared.notifySourcesChanged()
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
