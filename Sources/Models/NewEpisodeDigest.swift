// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// ONE message per refresh run. What it says, and where it leads.
///
/// The refresh already bundled per SHOW ("one message per show instead of one
/// per episode"), but not across them: five shows with new episodes meant five
/// messages and five sounds, because the posting loop built one content per
/// show. Bundling that stops at the show is not bundling. The run is the
/// event, so the run gets the message.
///
/// The text carries three cases, and each one says the most it honestly can:
/// a single new episode is worth naming; several episodes of one show are a
/// count under that show's name; several shows can only be counted.
///
/// The target is part of the message, not an afterthought: a message about ONE
/// show leads to that show, a collected one to the list of latest episodes.
/// "Opens the app" would put the reader back wherever they left off, which for
/// a collected message is nowhere near what it announced.
nonisolated enum NewEpisodeDigest {
    struct Show: Equatable, Sendable {
        let title: String
        let feedURL: String
        let newCount: Int
        /// The newest episode's title. Named only when it is the only one.
        let newestEpisodeTitle: String
    }

    /// Where a tap leads. Both cases are existing routes; nothing new to reach.
    enum Target: Equatable, Sendable {
        case show(feedURL: String)
        case latestEpisodes
    }

    struct Message: Equatable, Sendable {
        let title: String
        let body: String
        let target: Target
    }

    /// Groups messages of this kind in the notification centre.
    static let threadIdentifier = "maer.podcast.new-episodes"

    /// nil means there is nothing to say. Never a message about zero.
    static func message(for shows: [Show]) -> Message? {
        let withNews = shows.filter { $0.newCount > 0 }
        guard let first = withNews.first else { return nil }
        if withNews.count == 1 {
            return Message(
                title: first.title,
                body: first.newCount == 1
                    ? first.newestEpisodeTitle
                    : String(localized: "\(first.newCount) new episodes"),
                target: .show(feedURL: first.feedURL))
        }
        let episodes = withNews.reduce(0) { $0 + $1.newCount }
        return Message(
            title: String(localized: "New episodes"),
            body: String(localized: "\(episodes) new episodes in \(withNews.count) shows"),
            target: .latestEpisodes)
    }
}
