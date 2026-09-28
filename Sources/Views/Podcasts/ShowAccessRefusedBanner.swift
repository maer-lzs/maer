// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// What the show page offers for a lastingly refused feed: an address
/// that carries its access in itself and has no credentials here gets a new
/// link; every other one a sign-in. The same reading as the list of feeds
/// not followed yet, so one refusal has one answer everywhere.
nonisolated enum ShowAccessRemedy: Equatable, Sendable {
    case newLink
    case signIn

    static func of(tokenAddress: Bool, hasCredentials: Bool) -> ShowAccessRemedy {
        FeedAdoptionPending.Reason.from(meaning: .signIn, tokenAddress: tokenAddress,
                                        hasCredentials: hasCredentials) == .accessRefused ? .newLink : .signIn
    }
}

/// The notice at the top of a show whose feed the server keeps refusing.
/// Episodes and listening positions stay; the notice says so, and offers
/// the one way that can help.
struct ShowAccessRefusedBanner: View {
    let refusals: Int
    let isPremium: Bool
    let remedy: ShowAccessRemedy
    let onNewLink: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Access refused").font(.headline)
            } icon: {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            Group {
                if isPremium {
                    Text("The server has refused this paid feed \(refusals) times in a row.")
                } else {
                    Text("The server has refused this feed \(refusals) times in a row.")
                }
                switch remedy {
                case .newLink:
                    Text("Maybe the subscription has ended or the link is no longer valid.")
                case .signIn:
                    Text("Maybe the sign-in is no longer valid.")
                }
                Text("Your episodes and listening positions stay.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            switch remedy {
            case .newLink:
                Button("Enter new link", action: onNewLink)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("show-access-new-link")
            case .signIn:
                Button("Sign in", action: onSignIn)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("show-access-sign-in")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("show-access-refused")
    }
}
