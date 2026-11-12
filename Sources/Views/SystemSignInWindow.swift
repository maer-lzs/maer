// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AuthenticationServices
import SwiftUI

/// The system's sign-in window, as the view hands it over from its
/// environment (`webAuthenticationSession`): the provider's page runs in
/// it, never in a view of the app, and the app never sees what the person
/// types there. It catches the return scheme inside its own session, so
/// another app that registers the same scheme does not receive the return.
/// It shares cookies with Safari (`.shared`), so a sign-in at the provider
/// or at a guard in front of the server that the person already has holds
/// here too.
struct SystemSignInWindow: SignInWindow {
    let session: WebAuthenticationSession

    func signIn(at page: URL, returnScheme: String) async throws -> URL {
        do {
            return try await session.authenticate(using: page, callback: .customScheme(returnScheme),
                                                  preferredBrowserSession: .shared, additionalHeaderFields: [:])
        } catch let error as ASWebAuthenticationSessionError {
            // The person closed the window: a cancellation, not a failure.
            if error.code == .canceledLogin { throw CancellationError() }
            throw ABSSSO.Failure.windowUnavailable
        }
    }
}
