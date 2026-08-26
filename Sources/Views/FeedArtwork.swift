// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// A catalog row's cover when the row itself brought none — the
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

/// The ONE cover decision of a search-result row — a concrete view
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

/// THE free-catalog book tile — the four surfaces
/// (Home-Discover mix, audiobooks-tab row, free-audiobooks area, classical)
/// used to repeat the same MediaTile configuration; now they share one
/// component. It also fills the card's time line: where the popularity
/// search carried no `runtime`, the duration is resolved lazily from the
/// item metadata and cached, so the third line is FILLED rather than
/// reserved — an empty reserve is not acceptable in the card.
struct FreeCatalogBookTile: View {
    let item: LibraryItem
    var placeholderSystemImage: String = "book.closed"
    let onTap: () -> Void
    @State private var resolvedDuration: Double?

    private var duration: Double? { item.media?.duration ?? resolvedDuration }

    var body: some View {
        MediaTile(
            title: item.title,
            subtitle: item.author,
            coverURL: AppSession.shared.coverURL(forItemId: item.id),
            placeholderSystemImage: placeholderSystemImage,
            // Year first, then runtime — for catalog items whose
            // rights status the source does not state, the year is the only
            // hint the user has.
            meta: FreeCatalog.catalogMetaLine(
                year: item.media?.metadata?.publishedYear?.value,
                runtime: bookTimeLine(progress: nil, duration: duration).trimmingCharacters(in: .whitespaces),
                // The reading marker as a quiet meta part.
                readingVersion: FreeCatalogProvider.shared.readingVersion(forItemId: item.id)),
            titleLineLimit: 1,
            // The LICENCE at a glance — the source follows from the
            // section a tile stands in, the rights situation from nothing.
            // Unknown ⇒ no capsule (never guess).
            badgeText: FreeCatalogProvider.shared.licence(forItemId: item.id),
            onTap: onTap,
            corner: { FreeCatalogImportBadge(itemId: item.id) }
        )
        .task(id: item.id) {
            guard item.media?.duration == nil,
                  item.id.hasPrefix(FreeCatalog.archivePrefix) else { return }
            let identifier = String(item.id.dropFirst(FreeCatalog.archivePrefix.count))
            resolvedDuration = await ArchiveRuntimeService.shared.runtimeSeconds(identifier: identifier)
        }
    }
}
