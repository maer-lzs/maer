// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

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
    /// 🔴 The session is DOUBTED, never dissolved. A homeserver coming
    /// back up answers 401 for minutes; the old path logged out and DELETED
    /// the keychain token, which no restart could heal (the user had to
    /// reinstall). The rule this state exists for: **credentials are deleted
    /// by the user, never by a server answer.** While suspect the app keeps
    /// the token, shows the state at the source entry (G8) and re-probes
    /// itself. On network return and periodically.
    @Published private(set) var sessionSuspect = false
    /// Set once a probe reached the server AND it still said 401: then the
    /// token really is invalid and re-signing in is offered (prefilled).
    /// Still without deleting anything behind the user's back.
    @Published private(set) var needsReauth = false

    let apiClient: APIClient

    /// The server address as the source pages show it. One name for the
    /// fact, so the source page and the source map read the same thing.
    var serverAddress: String { apiClient.baseURL.absoluteString }

    init() {
        let storedURLString = KeychainStore.load(forKey: KeychainKey.serverURL) ?? ""
        let storedToken = KeychainStore.load(forKey: KeychainKey.apiToken)

        self.serverURLString = storedURLString
        let url = Self.normalizedURL(from: storedURLString) ?? URL(string: "https://example.invalid")!
        self.apiClient = APIClient(baseURL: url, token: storedToken)
        self.isLoggedIn = (storedToken?.isEmpty == false) && !storedURLString.isEmpty

        // A 401 marks the session SUSPECT. It never destroys the login.
        apiClient.onUnauthorized = { [weak self] in
            guard let self, self.isLoggedIn else { return }
            self.markSessionSuspect()
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
                errorMessage = String(localized: "Login failed. Please check username and password.")
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
            // A WORKING address goes into the known-server register.
            // Only on success, never credentials, never logged.
            KnownServers.remember(url.absoluteString, service: .audiobookshelf)
            KeychainStore.save(url.absoluteString, forKey: KeychainKey.serverURL)
            KeychainStore.save(token, forKey: KeychainKey.apiToken)
            apiToken = ""
            password = ""
            isLoggedIn = true
            // A SUCCESSFUL sign-in ends the doubt. Without this the
            // banner and both flags survived the fresh login until the next
            // app start. And the probe loop no longer runs once
            // `needsReauth` is set, so nothing else would have cleared them.
            sessionSuspect = false
            needsReauth = false
            // The book tab appears live once the source exists.
            AppSession.shared.notifySourcesChanged()
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
        }
    }

    /// The 401 path: doubt, probe, and only offer a fresh sign-in once the
    /// server is demonstrably reachable and still rejects us. Nothing is
    /// deleted here. Not even then.
    func markSessionSuspect() {
        guard !sessionSuspect else { return }
        sessionSuspect = true
        errorMessage = String(localized: "Session expired, checking the server…")
        Logger.library.warning("ABS session SUSPECT after 401 — token kept, probing")
        Task { await probeSession() }
    }

    /// Self-healing probe: as long as the server does not answer at all we
    /// stay suspect and try again later (the reverse-proxy start window);
    /// a clean answer resolves the doubt; a reachable server that still
    /// says 401 means the token is really invalid → offer re-auth.
    func probeSession() async {
        var delaySeconds: UInt64 = 5
        while sessionSuspect, !needsReauth {
            switch await apiClient.probeAuthorization() {
            case .authorized:
                sessionSuspect = false
                errorMessage = nil
                Logger.library.notice("ABS session RECOVERED — server answered again")
                return
            case .rejected:
                needsReauth = true
                errorMessage = String(localized: "Session expired. Please sign in again.")
                Logger.library.warning("ABS session REJECTED by a reachable server — sign-in offered, token kept")
                return
            case .unreachable:
                // Exactly the homeserver-restart window: keep everything,
                // back off, try again (capped at a minute).
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                delaySeconds = min(delaySeconds * 2, 60)
            }
        }
    }

    /// The USER's sign-out. The only path that may drop the token.
    func logout() {
        KeychainStore.delete(forKey: KeychainKey.apiToken)
        // Empty the client too. `isAvailable` (tab visibility, search
        // fan-out) must flip with the logout, not only the root switch.
        apiClient.clearToken()
        isLoggedIn = false
        sessionSuspect = false
        needsReauth = false
        Logger.library.notice("ABS logout by USER — token removed from the keychain")
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
