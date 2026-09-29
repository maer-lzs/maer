// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// 🔴 The visible half of "credentials are deleted by the user, not
/// by a server answer". While the session is doubted the app keeps the token
/// and probes by itself. But silence would read as "everything is fine, the
/// library is just empty". So the state says which of the two it is:
///
/// * **checking**. The server does not answer yet (the homeserver restart
///   window). Nothing is lost, the probe repeats on its own.
/// * **sign-in needed**. A reachable server rejected the token. Only THEN
///   is re-authentication offered, with the address and user prefilled;
///   the stored token still stays until the user replaces it.
struct AbsSessionStateBanner: View {
    @ObservedObject private var auth = AppSession.shared.authViewModel
    @State private var showsSignIn = false

    var body: some View {
        if auth.sessionSuspect {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(auth.needsReauth
                         ? "Your server rejected the saved sign-in."
                         : "Your server isn’t answering, checking again.")
                        .font(.subheadline.weight(.medium))
                } icon: {
                    Image(systemName: auth.needsReauth
                          ? "person.badge.key" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(auth.needsReauth ? .orange : .secondary)
                }
                Text(auth.needsReauth
                     ? "Nothing was deleted. Sign in again to continue. Your address and user name are already filled in."
                     : "Your saved sign-in is untouched. Downloaded titles keep playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if auth.needsReauth {
                    Button("Sign In Again") { showsSignIn = true }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        .accessibilityIdentifier("abs-session-reauth")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
            .accessibilityIdentifier("abs-session-banner")
            .sheet(isPresented: $showsSignIn) {
                SetupView(viewModel: auth)
                    .followsAppearanceChoice()
            }
        }
    }
}
