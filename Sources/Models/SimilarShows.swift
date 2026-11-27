// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

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

    static let most = 6
    static let keepsForSeconds: Double = 6 * 3600

    static func plan(categories: [String], language: String?, podroll: [PodcastRemoteItem]?,
                     directory: PodcastDirectorySelection.Kind, guarded: Bool) -> [Step] { [] }

    static func pick(podroll: [Pick], directory: [Pick], ownFeed: String, subscribed: Set<String>) -> [Pick] { [] }

    static func heading(podrollShown: Bool, genre: String?) -> String? { nil }
}
