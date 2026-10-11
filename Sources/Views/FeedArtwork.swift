// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// A catalog row's cover when the row itself brought none. The
/// artwork is resolved LAZILY from the feed's channel image (persistently
/// cached, negatives included) and rendered through the shared image path.
/// Passed as `coverOverride` (as `MediaTile` takes any artwork), so framing, clipping,
/// dimming and badges stay with `MediaRowContent`; only the picture is ours.
///
/// Generic on purpose: curated entries AND directory hits without artwork
/// use the same view. No radio-play special path.
struct FeedArtwork: View {
    let feedURL: String
    var placeholderSystemImage: String = "mic"

    /// nil = not resolved yet, .some(nil) = the feed states no image.
    @State private var resolved: URL??

    var body: some View {
        Group {
            if let url = resolved ?? nil {
                CachedAsyncImage(url: url, useThumbnail: true) { image, pixels in
                    CoverFitting(image: image, pixelSize: pixels, backdrop: .neutral)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        // No layout jump: the row sizes the cover slot, the placeholder and
        // the image fill the SAME square. Only the content swaps.
        .task(id: feedURL) {
            // A tile that appears stays a moment before the feed is asked
            // (`TileDwell`); a tile that scrolls away cancels the stay.
            resolved = .some(await TileDwell.standing { await FeedArtworkService.shared.artworkURL(feedURL: feedURL) })
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay(Image(systemName: placeholderSystemImage).foregroundStyle(.secondary))
    }
}

/// The ONE cover decision of a search-result row. A concrete view
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
            CachedAsyncImage(url: result.coverURL, useThumbnail: true) { image, pixels in
                CoverFitting(image: image, pixelSize: pixels, backdrop: .neutral)
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(Image(systemName: placeholderSystemImage).foregroundStyle(.secondary))
            }
        }
    }
}

/// THE free-catalog book tile. The four surfaces
/// (Home-Discover mix, audiobooks-tab row, free-audiobooks area, classical)
/// used to repeat the same MediaTile configuration; now they share one
/// component. It also fills the card's time line: where the popularity
/// search carried no `runtime`, the duration is resolved lazily from the
/// item metadata and cached, so the third line is FILLED rather than
/// reserved. An empty reserve is not acceptable in the card.
struct FreeCatalogBookTile: View {
    @Environment(\.catalogFacts) private var catalogFacts
    @Environment(\.itemRouter) private var router
    let item: LibraryItem
    var placeholderSystemImage: String = "book.closed"
    /// On a surface whose WHOLE collection carries one uniform rights
    /// answer, the standard stands once at the top and the tile stays
    /// quiet about it. Deviations (a stated licence, a computed public
    /// domain) still show; only the repetition falls.
    var hidesUnstatedRights: Bool = false
    let onTap: () -> Void
    @State private var resolvedDuration: Double?

    private var duration: Double? { item.media?.duration ?? resolvedDuration }

    var body: some View {
        MediaTile(
            title: item.title,
            // A creator field that IS a URL is no author name (measured on
            // archive uploads: "http://sites.google.co…"). Same rule as the
            // rights capsule: a value we cannot read is not shown as one.
            subtitle: FreeCatalog.displayableAuthor(item.author),
            coverURL: router.coverURL(item.id),
            placeholderSystemImage: placeholderSystemImage,
            lock: .none,
            // Year first, then runtime. For catalog items whose
            // rights status the source does not state, the year is the only
            // hint the user has.
            meta: FreeCatalog.catalogMetaLine(
                year: item.media?.metadata?.publishedYear?.value,
                runtime: bookTimeLine(progress: nil, duration: duration).trimmingCharacters(in: .whitespaces),
                // The reading marker as a quiet meta part.
                readingVersion: catalogFacts.readingVersion(item.id)),
            titleLineLimit: 1,
            // The LICENCE at a glance. The source follows from the
            // section a tile stands in, the rights situation from nothing.
            // Unknown ⇒ no capsule (never guess).
            badgeText: {
                let licence = catalogFacts.licence(item.id)
                return (hidesUnstatedRights && licence == FreeCatalog.unstatedRights)
                    ? nil : licence
            }(),
            onTap: onTap,
            corner: { FreeCatalogImportBadge(itemId: item.id) }
        )
        .task(id: item.id) {
            guard item.media?.duration == nil,
                  item.id.hasPrefix(FreeCatalog.archivePrefix) else { return }
            let identifier = FreeCatalog.archiveIdentifier(of: item.id) ?? item.id
            // The tile stays a moment before the runtime is asked (`TileDwell`).
            resolvedDuration = await TileDwell.standing { await ArchiveRuntimeService.shared.runtimeSeconds(identifier: identifier) }
        }
    }
}
