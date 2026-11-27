// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Asks what `SimilarShows.plan` says for one show and keeps a good answer
/// six hours; a failure is not kept. Nothing is subscribed here.
@MainActor
enum SimilarShowsLoader {
    struct Answer: Equatable {
        let heading: String
        let picks: [SimilarShows.Pick]
    }

    private static var kept: [String: (at: Date, answer: Answer)] = [:]

    /// A feed with access data: a token in the address, a login, a mirror.
    static func guarded(_ show: PodcastShow) -> Bool {
        show.origin != nil || PodcastFeedAddress.isTokenFeedURL(show.feedURL)
            || PodcastFeedAuth.hasCredentials(feedKey: PodcastIdentity.feedKey(show.feedURL))
    }

    static func answer(for show: PodcastShow, subscribed: Set<String>, now: Date = Date()) async -> Answer? {
        let key = PodcastIdentity.normalizeFeedURL(show.feedURL)
        if let held = kept[key], now.timeIntervalSince(held.at) < SimilarShows.keepsForSeconds { return held.answer }
        let asked: SimilarShows.Directory = switch PodcastDirectorySelection.current {
        case .itunes: .itunes
        case .podcastIndex: .podcastIndex
        case .none: .none
        }
        let steps = SimilarShows.plan(categories: show.categories ?? [], language: show.language, podroll: show.podroll,
                                      directory: asked, guarded: guarded(show))
        var podroll: [SimilarShows.Pick] = []
        var directory: [SimilarShows.Pick] = []
        var genre: String?
        for step in steps {
            switch step {
            case .podroll(let items):
                podroll = items.compactMap { item in
                    guard let url = item.feedUrl else { return nil }
                    return SimilarShows.Pick(feedURL: url, title: item.title ?? URL(string: url)?.host ?? url,
                                             artworkURL: nil, fromPodroll: true)
                }
            case .charts(let genreId, let language):
                genre = PodcastGenres.curated.first { $0.itunesGenreId == genreId }?.title
                    ?? PodcastCategoryMapping.appleCategory(forGenreId: genreId)
                do {
                    directory = try await ITunesDirectory().topPodcasts(language: language, genreId: genreId, limit: 12)
                        .map { SimilarShows.Pick(feedURL: $0.feedURL, title: $0.title, artworkURL: $0.artworkURL, fromPodroll: false) }
                } catch {
                    Logger.rss.notice("SIMILAR chart failed: \(FailureReason.of(error), privacy: .public)")
                    return nil
                }
            case .trending(let category, let language):
                genre = category
                guard let index = PodcastDirectorySelection.directory() as? PodcastIndexDirectory else { continue }
                do {
                    directory = try await index.trending(max: 12, lang: language, categories: [category])
                        .map { SimilarShows.Pick(feedURL: $0.feedURL, title: $0.title, artworkURL: $0.artworkURL, fromPodroll: false) }
                } catch {
                    Logger.rss.notice("SIMILAR trending failed: \(FailureReason.of(error), privacy: .public)")
                    return nil
                }
            }
        }
        let picks = SimilarShows.pick(podroll: podroll, directory: directory, ownFeed: show.feedURL, subscribed: subscribed)
        let answer = Answer(heading: SimilarShows.heading(podrollShown: picks.contains { $0.fromPodroll }, genre: genre)
                                ?? String(localized: "Similar Shows"),
                            picks: picks)
        kept[key] = (now, answer)
        return answer
    }
}
