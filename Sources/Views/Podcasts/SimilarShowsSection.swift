// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// "Similar Shows" under the episodes of a show page: asked when the
/// section appears, at most six tiles; a tap opens the show's page, nothing
/// is subscribed here. Without a pick the section is not there.
struct SimilarShowsSection: View {
    let show: PodcastShow
    let subscribed: Set<String>
    @State private var answer: SimilarShowsLoader.Answer?

    var body: some View {
        Group {
            if let answer, !answer.picks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    RowHeading.plain(verbatim: answer.heading)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(answer.picks, id: \.feedURL) { pick in
                                RecommendationTile(result: PodcastSearchResult(title: pick.title, author: nil,
                                                                               artworkURL: pick.artworkURL, feedURL: pick.feedURL),
                                                   subtitle: pick.fromPodroll ? String(localized: "Named by this show") : nil)
                                .cardRowSlot()
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 12)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task(id: show.feedURL) {
            answer = await SimilarShowsLoader.answer(for: show, subscribed: subscribed)
        }
    }
}
