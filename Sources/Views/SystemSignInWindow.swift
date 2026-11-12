// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AuthenticationServices
import UIKit

/// The system's sign-in window (`ASWebAuthenticationSession`): the provider's
/// page runs in it, never in a view of the app, and the app never sees what
/// the person types there. It catches the return scheme inside its own
/// session, so another app that registers the same scheme does not receive
/// the return. It shares cookies with Safari, so a sign-in at the provider
/// or at a guard in front of the server that the person already has holds
/// here too.
final class SystemSignInWindow: NSObject, SignInWindow, ASWebAuthenticationPresentationContextProviding {
    /// Held while the window is open; the system closes a session nobody holds.
    private var session: ASWebAuthenticationSession?

    func signIn(at page: URL, returnScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: page, callback: .customScheme(returnScheme)) { [weak self] url, error in
                self?.session = nil
                if let url {
                    done.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    done.resume(throwing: CancellationError())
                } else {
                    done.resume(throwing: error ?? URLError(.unknown))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                self.session = nil
                done.resume(throwing: ABSSSO.Failure.windowUnavailable)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
    }
}
