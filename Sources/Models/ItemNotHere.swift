// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A title that no source on this device can name, said in words.
///
/// The providers used to throw `NSError(domain: "RSSProvider", code: 404)`
/// and its siblings. No server had answered 404: the number was made up at
/// the lookup, and the system turned it into "The operation couldn't be
/// completed. (RSSProvider error 404.)" on the screen. Each case here is a
/// fact the provider knows, and each has a sentence.
nonisolated enum ItemNotHere: LocalizedError, Equatable {
    /// A podcast episode that is in none of the stores this device holds:
    /// not in the subscription stock, not among the browsed or listened
    /// episodes.
    case episodeNotLoadedHere
    /// The server's show no longer lists the episode, or the id names none.
    case episodeNotOnServer
    /// A local file that the library no longer holds.
    case fileGone

    var errorDescription: String? {
        switch self {
        case .episodeNotLoadedHere:
            return String(localized: "This episode is not available on this device yet.")
        case .episodeNotOnServer:
            return String(localized: "This episode is no longer on the server.")
        case .fileGone:
            return String(localized: "This file is no longer on this device.")
        }
    }
}
