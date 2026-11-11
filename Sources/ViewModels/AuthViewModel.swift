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
    /// the token, shows the state at the source entry and re-probes
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

    /// The stored access could not be read (the device not unlocked since it
    /// started): the person is not known to be signed out, so the sign-in
    /// state stays, the client has no token and the source is not
    /// available, until `rereadIfUnknown` reads it.
    @Published private(set) var accessUnknown: Bool

    /// The keychain read, a seam for the witness.
    private let readKeychain: (String) -> KeychainRead

    init(read: @escaping (String) -> KeychainRead = { KeychainStore.read(forKey: $0) }) {
        self.readKeychain = read
        let storedURL = read(KeychainKey.serverURL)
        let storedToken = read(KeychainKey.apiToken)
        let state = SignInState.of(url: storedURL, token: storedToken)
        let storedURLString = storedURL.value ?? ""

        self.serverURLString = storedURLString
        let url = Self.normalizedURL(from: storedURLString) ?? URL(string: "https://example.invalid")!
        self.apiClient = Self.makeClient(baseURL: url, token: storedToken.value)
        self.isLoggedIn = state.signedIn
        self.accessUnknown = state.unknown
        apiClient.accessUnknown = state.unknown
        if state.unknown {
            Logger.library.notice("ABS access unreadable at start: signed in kept, read again on return")
        }
        // A device that stored a server before the server was remembered
        // takes the stored address as its server, without a switch, also
        // when it is signed out: the address stays after a sign-out.
        AppStorageKeys.normalizeABSServers()
        if !storedURLString.isEmpty, AppStorageKeys.string(AppStorageKeys.absSignedInServer) == nil {
            AppStorageKeys.set(ABSServerScope.identity(of: url.absoluteString), for: AppStorageKeys.absSignedInServer)
        }

        // A 401 marks the session SUSPECT. It never destroys the login.
        apiClient.onUnauthorized = { [weak self] in
            guard let self, self.isLoggedIn else { return }
            self.markSessionSuspect()
        }
    }

    /// Reads the access again while it is unknown. Returns true when it now
    /// reads as signed in: the client has its address and token, and the
    /// caller loads the library. A missing access ends as signed out.
    @discardableResult
    func rereadIfUnknown() -> Bool {
        guard accessUnknown else { return false }
        let storedURL = readKeychain(KeychainKey.serverURL)
        let storedToken = readKeychain(KeychainKey.apiToken)
        let state = SignInState.of(url: storedURL, token: storedToken)
        guard !state.unknown else { return false }
        let storedURLString = storedURL.value ?? ""
        serverURLString = storedURLString
        if let url = Self.normalizedURL(from: storedURLString) { apiClient.updateBaseURL(url) }
        if let token = storedToken.value { apiClient.updateToken(token) }
        apiClient.accessUnknown = false
        accessUnknown = false
        isLoggedIn = state.signedIn
        Logger.library.notice("ABS access read again: signedIn=\(state.signedIn, privacy: .public)")
        return state.signedIn
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
        return ErrorSentence.of(error)
    }

    /// The one way a client of the server comes into being: the shared one
    /// at the start, a fresh one for every sign-in.
    static func makeClient(baseURL: URL, token: String?) -> APIClient {
        APIClient(baseURL: baseURL, token: token)
    }

    /// Connects via username/password (POST /login → token) OR with a directly
    /// entered API token; the connection is then verified via a library fetch
    /// and the token stored in the keychain.
    ///
    /// The sign-in runs on a fresh client without a token: the shared one
    /// still carries the token of the server signed in before, and the new
    /// address may name another server. Only a sign-in that worked hands
    /// address and token to the shared client; one that failed leaves it as
    /// it was, also for the same address.
    func connect() async {
        errorMessage = nil
        guard let url = Self.normalizedURL(from: serverURLString) else {
            errorMessage = String(localized: "Please enter a valid server address, e.g. https://audio.example.com")
            return
        }

        isLoading = true
        defer { isLoading = false }
        let trial = Self.makeClient(baseURL: url, token: nil)

        let token: String
        switch loginMode {
        case .password:
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty, !password.isEmpty else {
                errorMessage = String(localized: "Please enter username and password.")
                return
            }
            do {
                token = try await trial.login(username: user, password: password)
            } catch APIError.http(401, _) {
                errorMessage = await AccessGuard.sentence(after: String(localized: "Login failed. Please check username and password."),
                                                          address: serverURLString)
                return
            } catch {
                errorMessage = await AccessGuard.sentence(after: Self.friendlyMessage(for: error), address: serverURLString)
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

        trial.updateToken(token)
        do {
            _ = try await trial.fetchLibraries()
            // Whether this is another server than the one signed in before,
            // by the one rule of a switch.
            // Another user at the same address is another account
            // (`ServerAddressSwitch.isAccountSwitch`): the user's id is asked
            // once. A stored sign-in whose user is not noted (a build before
            // the note) asks the server with the stored token; a user that
            // stays unknown on either side counts as another account.
            let formerAddress = apiClient.baseURL.absoluteString
            let serverSwitched = ServerAddressSwitch.isSwitch(from: formerAddress, to: url.absoluteString)
            let formerAccess = !(KeychainStore.load(forKey: KeychainKey.apiToken) ?? "").isEmpty
            let userId = await Self.userId(of: trial, side: "new")
            var formerUser = AppStorageKeys.string(AppStorageKeys.absSignedInUser) ?? ""
            if formerUser.isEmpty, formerAccess, !serverSwitched {
                formerUser = await Self.userId(of: apiClient, side: "stored") ?? ""
            }
            let switched = ServerAddressSwitch.isAccountSwitch(
                fromAddress: formerAddress, fromUser: formerUser,
                toAddress: url.absoluteString, toUser: userId ?? "", unknownIsSwitch: formerAccess)
            // The shared client takes the server only now that it answered.
            apiClient.updateBaseURL(url)
            apiClient.updateToken(token)
            // A WORKING address goes into the known-server register.
            // Only on success, never credentials, never logged.
            KnownServers.remember(url.absoluteString, service: .audiobookshelf)
            AppStorageKeys.noteABSSignIn(url.absoluteString, nowMs: Date().timeIntervalSince1970 * 1000)
            AppStorageKeys.set(userId, for: AppStorageKeys.absSignedInUser)
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
            accessUnknown = false
            apiClient.accessUnknown = false
            // The titles of the former server leave the widget and the
            // device's search, as at a sign out, before the sources change,
            // so a pass for the new server writes after them; a sign-in
            // again to the same server keeps them.
            if switched { await Self.forgetFormerServer() }
            // The stands the user before queued at this server stay theirs;
            // another server keeps its own waiting under its name.
            if switched, !serverSwitched { await SyncQueue.shared.forgetPending(onServer: formerAddress) }
            // The book tab appears live once the source exists.
            AppSession.shared.notifySourcesChanged()
        } catch {
            errorMessage = await AccessGuard.sentence(after: Self.friendlyMessage(for: error), address: serverURLString)
        }
    }

    #if DEBUG
    /// Harness door: the two error states a sight check asks for by launch
    /// argument (`UITestSeed`), without a server. Rejected: the server
    /// answered and refused; otherwise: it is not answering.
    func _seedSessionState(rejected: Bool) {
        sessionSuspect = true
        needsReauth = rejected
        errorMessage = rejected
            ? String(localized: "Session expired. Please sign in again.")
            : String(localized: "Session expired, checking the server…")
    }
    #endif

    /// The 401 path: doubt, probe, and only offer a fresh sign-in once the
    /// server is demonstrably reachable and still rejects us. Nothing is
    /// deleted here. Not even then.
    func markSessionSuspect() {
        // An access that could not be read is no rejected one: the client
        // sends nothing then (`APIError.accessUnknown`), and no doubt starts.
        guard !sessionSuspect, !accessUnknown else { return }
        #if DEBUG
        // The seeded harness has no book server: its token lives only in
        // memory, so any 401 it meets says nothing about a sign-in.
        if UITestSeed.isActive { return }
        #endif
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
        accessUnknown = false
        apiClient.accessUnknown = false
        Logger.library.notice("ABS logout by USER — token removed from the keychain")
        AppSession.shared.notifySourcesChanged()
        Task { await Self.forgetFormerServer() }
    }

    /// The user's id as the server names it (`api/me`); nil, with a log
    /// line, when the server does not answer with one.
    static func userId(of client: APIClient, side: String) async -> String? {
        do {
            guard let id = try await client.fetchUserId(), !id.isEmpty else {
                Logger.library.notice("AUTH user id unknown side=\(side, privacy: .public): the answer carries none")
                return nil
            }
            return id
        } catch {
            Logger.library.error("AUTH user id not read side=\(side, privacy: .public) reason=\(FailureReason.of(error), privacy: .public)")
            return nil
        }
    }

    /// What a server leaves on the device beside its token: a player on one
    /// of its titles and the widget's rows (`ServerLeaving`, every row, as
    /// the welcome page follows), and the books in the device's search. A
    /// sign out and a sign-in to another server both forget it here.
    static func forgetFormerServer(player: PlayerCoordinator? = nil) async {
        await ServerLeaving.forget(ItemNamespace.isAudiobookshelf, covers: .audiobookshelf, allRows: true, player: player)
        if #available(iOS 27, *) { await SpotlightIndex.forget() }
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

/// What the stored address and token say about signing in. Either one
/// unreadable makes the answer unknown, and unknown keeps the person signed
/// in: a start before the first unlock after a restart must not look like a
/// sign-out. A missing value is a real answer and signs out.
nonisolated enum SignInState {
    static func of(url: KeychainRead, token: KeychainRead) -> (signedIn: Bool, unknown: Bool) {
        if url == .unreadable || token == .unreadable { return (true, true) }
        let signedIn = !(url.value ?? "").isEmpty && !(token.value ?? "").isEmpty
        return (signedIn, false)
    }
}
