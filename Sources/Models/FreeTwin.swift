// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The free feed of a paid show whose access is lastingly refused: which
/// directory hit counts as that twin. Only a hit with the same show title
/// and without any mark of a paid feed; the first such hit wins, because
/// the directory already orders by relevance. Nothing is guessed beyond the
/// title: the person sees the found feed named and decides.
nonisolated enum FreeTwin {
    static func pick(hits: [(title: String, feedURL: String)], showTitle: String,
                     isPremium: (String) -> Bool) -> Int? {
        hits.firstIndex { hit in
            PodcastPremiumMatch.sameShow(titleA: hit.title, titleB: showTitle) && !isPremium(hit.feedURL)
        }
    }

    /// The address as it travels: a user or password in it is taken out,
    /// and nothing else changes. A feed address is not a server address:
    /// a trailing slash or the case of a path can name another feed.
    static func address(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { return trimmed }
        let afterScheme = trimmed[schemeEnd.upperBound...]
        let authorityEnd = afterScheme.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard let at = authority.lastIndex(of: "@") else { return trimmed }
        return String(trimmed[..<schemeEnd.upperBound]) + String(authority[authority.index(after: at)...])
            + String(afterScheme[authorityEnd...])
    }

    /// What the show offers: a remembered free address comes first; a search
    /// result only when nothing is remembered. A declined offer is none.
    struct Offer: Equatable, Sendable {
        let feedURL: String
        /// The found feed's title when the directory named it.
        let title: String?
    }

    static func offer(remembered: String?, searched: [String]?, declined: Bool) -> Offer? {
        guard !declined else { return nil }
        if let remembered, !remembered.isEmpty { return Offer(feedURL: remembered, title: nil) }
        if let searched, searched.count == 2, !searched[0].isEmpty {
            return Offer(feedURL: searched[0], title: searched[1])
        }
        return nil
    }
}
