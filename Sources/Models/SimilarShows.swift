// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// "Similar Shows" under a show: first
/// what the feed itself names (its podroll), else the chart of its genre,
/// asked in the show's language and then headed "More from <genre>". A
/// feed with access data (a token, a login, a mirror) asks no directory:
/// its topics would leave the device with it.
nonisolated enum SimilarShows {
    enum Step: Equatable, Sendable {
        case podroll([PodcastRemoteItem])
        case charts(genreId: Int, language: String)
        case trending(category: String, language: String)
    }

    struct Pick: Equatable, Sendable {
        let feedURL: String
        let title: String
        let artworkURL: String?
        let fromPodroll: Bool
    }

    /// Which directory may be asked, as `PodcastDirectorySelection` says.
    enum Directory: Equatable, Sendable { case itunes, podcastIndex, none }

    static let most = 6
    static let keepsForSeconds: Double = 6 * 3600

    /// What is asked, in order. The podroll's entries with an address need
    /// no request; one with only a GUID would need a directory lookup the
    /// app does not have, and is left out.
    static func plan(categories: [String], language: String?, podroll: [PodcastRemoteItem]?,
                     directory: Directory, guarded: Bool) -> [Step] {
        var steps: [Step] = []
        let addressed = (podroll ?? []).filter { !($0.feedUrl ?? "").isEmpty }
        if !addressed.isEmpty { steps.append(.podroll(addressed)) }
        guard !guarded else { return steps }
        let lang = language.map { String($0.prefix(2)).lowercased() }.flatMap { $0.isEmpty ? nil : $0 } ?? "en"
        switch directory {
        case .itunes:
            if let genre = PodcastCategoryMapping.itunesGenreIds(for: categories).first {
                steps.append(.charts(genreId: genre, language: lang))
            }
        case .podcastIndex:
            if let category = categories.first { steps.append(.trending(category: category, language: lang)) }
        case .none:
            break
        }
        return steps
    }

    /// At most six: the podroll first, then the directory; never the show
    /// itself, a subscribed show or the same address twice.
    static func pick(podroll: [Pick], directory: [Pick], ownFeed: String, subscribed: Set<String>) -> [Pick] {
        var seen: Set<String> = [PodcastIdentity.normalizeFeedURL(ownFeed)]
        seen.formUnion(subscribed.map(PodcastIdentity.normalizeFeedURL))
        var out: [Pick] = []
        for candidate in podroll + directory where out.count < most {
            if seen.insert(PodcastIdentity.normalizeFeedURL(candidate.feedURL)).inserted { out.append(candidate) }
        }
        return out
    }

    /// "Similar Shows" when the feed named any, "More from <genre>" when
    /// only the chart of the genre speaks.
    static func heading(podrollShown: Bool, genre: String?) -> String? {
        guard !podrollShown, let genre else { return String(localized: "Similar Shows") }
        return String(localized: "More from \(genre)")
    }
}
