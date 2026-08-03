// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// c125ccd: a catalog row's cover when the row itself brought none — the
/// artwork is resolved LAZILY from the feed's channel image (persistently
/// cached, negatives included) and rendered through the shared image path.
/// Passed as `coverOverride` (the Y58 pattern), so framing, clipping,
/// dimming and badges stay with `MediaRowContent`; only the picture is ours.
///
/// Generic on purpose: curated entries AND directory hits without artwork
/// use the same view — no radio-play special path.
struct FeedArtwork: View {
    let feedURL: String
    var placeholderSystemImage: String = "mic"

    /// nil = not resolved yet, .some(nil) = the feed states no image.
    @State private var resolved: URL??

    var body: some View {
        Group {
            if let url = resolved ?? nil {
                CachedAsyncImage(url: url, useThumbnail: true) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        // No layout jump: the row sizes the cover slot, the placeholder and
        // the image fill the SAME square — only the content swaps.
        .task(id: feedURL) {
            resolved = .some(await FeedArtworkService.shared.artworkURL(feedURL: feedURL))
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay(Image(systemName: placeholderSystemImage).foregroundStyle(.secondary))
    }
}

/// c125ccd: the ONE cover decision of a search-result row — a concrete view
/// (never `AnyView`; erasure is taxed per row creation, cell-cost rule).
/// Radio hits keep the gated station artwork; a catalog show WITHOUT its own
/// image resolves the feed's channel artwork; everything else falls through
/// to `MediaRowContent`'s plain `coverURL` path.
struct SearchRowCover: View {
    let result: SearchResult
    var placeholderSystemImage: String = "mic"

    var body: some View {
        switch result.kind {
        case .radioStation:
            RadioArtwork(stationID: result.id, faviconURL: result.coverURL, name: result.title)
        case .catalogShow where result.coverURL == nil:
            FeedArtwork(feedURL: result.id, placeholderSystemImage: placeholderSystemImage)
        default:
            CachedAsyncImage(url: result.coverURL, useThumbnail: true) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(Image(systemName: placeholderSystemImage).foregroundStyle(.secondary))
            }
        }
    }
}
