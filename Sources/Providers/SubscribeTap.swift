// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What one subscribe tap of the person did (`PodcastSubscribeBadge.subscribe`),
/// and whether the subscription took the show over. Only a subscription that
/// stands takes it over: then the browsed episodes of the feed step aside for
/// the subscription stock. A tap that subscribed nothing forgets nothing; the
/// remembered episodes the person heard without a subscription carry the
/// names of their positions, and losing them on a failed tap left nameless
/// positions behind.
enum SubscribeTap: Equatable {
    /// Subscribed here (also while Audiobookshelf was unread, noted) or on
    /// the server.
    case subscribed
    /// Audiobookshelf holds the show: the server's episodes answer, bridged
    /// to the feed's ids, so the browsed half steps aside as for a
    /// subscription.
    case heldOnServer
    /// Audiobookshelf could not be read and nothing was subscribed; the
    /// notice host says it (`serverUnreadNotice`).
    case setOut
    /// Nothing subscribed: the server refused or the feed did not load.
    case failed(sentence: String)

    var takesShowOver: Bool {
        switch self {
        case .subscribed, .heldOnServer: true
        case .setOut, .failed: false
        }
    }

    /// The answer of the local branch.
    static func local(_ answer: PodcastSubscriptions.LocalSubscription) -> SubscribeTap {
        switch answer {
        case .subscribed, .subscribedUnchecked: .subscribed
        case .onServer: .heldOnServer
        case .setOut: .setOut
        case .notSubscribed: .failed(sentence: String(localized: "The feed could not be loaded."))
        }
    }

    /// The answer of the server branch: `subscribeOnServer` hands back the
    /// reason when it failed, nil when the show stands.
    static func server(failure: String?) -> SubscribeTap {
        failure.map { .failed(sentence: $0) } ?? .subscribed
    }
}
