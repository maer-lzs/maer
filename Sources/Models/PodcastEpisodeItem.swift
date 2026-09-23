// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// PodcastShow + episode → LibraryItem (source-agnostic). The namespace in the
/// `guid`/`id` (`rss:`/`abspod:`) routes playback/cover/progress to the right
/// source. `nonisolated`: pure mapping, used from the off-main podcast-sections
/// compute.
///
/// The ONE mapping from an episode to an entry. Both providers kept a private
/// copy of it, field for field the same; it lives below the views so a
/// provider can ask it without reaching up into them.
nonisolated func podcastLibraryItem(show: PodcastShow, episode: PodcastEpisode) -> LibraryItem {
    LibraryItem(
        id: episode.guid,
        media: LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: episode.title, authorName: show.title, narratorName: nil,
                seriesName: show.title, genres: nil, publishedYear: nil,
                description: episode.description
            ),
            duration: episode.duration, chapters: nil,
            tracks: [ABSAudioTrack(index: 0, startOffset: nil, duration: episode.duration,
                                   contentUrl: episode.audioURL, metadata: nil)]
        ),
        addedAt: episode.pubDate
    )
}
