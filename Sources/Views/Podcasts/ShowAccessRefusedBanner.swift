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
    /// A free twin the person may switch to; never switched silently.
    var freeTwin: FreeTwin.Offer? = nil
    var onSwitch: () -> Void = {}
    var onDecline: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            if let freeTwin {
                Group {
                    if let title = freeTwin.title {
                        Text("There is a free feed of this show: \(title). Switch? Your listening positions go with it, and the paid link stays remembered for later.")
                    } else {
                        Text("There is a free feed of this show. Switch? Your listening positions go with it, and the paid link stays remembered for later.")
                    }
                }
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                // Side by side while they fit the width; at the large sizes
                // one under the other, chosen by the size, not by trying.
                let buttons = Group {
                    // The prominent style keeps its label on one line and
                    // cut it at the large sizes; the label wraps instead.
                    Button(action: onSwitch) {
                        Text("Switch to free feed")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("show-access-free-twin-switch")
                    Button("No", action: onDecline)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("show-access-free-twin-no")
                }
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) { buttons }
                } else {
                    HStack(spacing: 8) { buttons }
                }
            }
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
