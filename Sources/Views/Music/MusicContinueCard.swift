// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// A playlist on the Home "Continue" row. Reuses the 2×2 mosaic
/// (`PlaylistArtwork`) as the cover (no new artwork path) over the title and a
/// progress bar; tapping resumes the playlist at its bookmarked position (the
/// provider hands `open` a `userMediaProgress` / the local backup covers same
/// device). Sized like the other featured continue cards.
struct MusicContinueCard: View {
    @Environment(\.itemRouter) private var router
    let item: LibraryItem
    let progress: BookProgress?
    @ObservedObject var playerCoordinator: PlayerCoordinator

    @State private var coverURLs: [URL] = []
    /// The text-block color comes from the cover EDGE the block
    /// touches. The SAME cached CoverColorLoader extraction the playlist
    /// cards use (one mechanism, deterministic fallback without a cover).
    /// EXACT Featured-card anatomy. The mixed Continue row holds
    /// ONE card format (book · episode · album/playlist), so this card uses
    /// the same width, cover face, tint block, line reserves and pill as
    /// Book-/PodcastFeaturedCard; the mosaic/album cover simply fills the
    /// same frame. Color from the (bottom) cover like the playlist cards.
    @StateObject private var colorLoader = CoverColorLoader()
    @ScaledMetric(relativeTo: .subheadline) private var pillReserve: CGFloat = 40
    @ScaledMetric(relativeTo: .headline) private var titleMinHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var subMinHeight: CGFloat = 20

    private var mosaicKey: String { item.id }
    private var isAlbum: Bool { AppSession.shared.musicProvider(for: item.id).kind(of: item.id) == .album }

    private var tint: Color {
        colorLoader.hasAccent ? colorLoader.accent : PlaylistArtwork.color(for: item.id)
    }

    /// Caption: progress percent · relative last-played (the Featured cards'
    /// time-info slot); blank line reserves the height when unknown.
    private var captionText: String {
        var parts: [String] = []
        if let fraction = progress?.fraction, fraction > 0 {
            parts.append("\(Int((min(max(fraction, 0), 1)) * 100)) %")
        }
        if let ts = progress?.lastUpdate, ts > 0 {
            parts.append(Date(timeIntervalSince1970: ts / 1000)
                .formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button {
            Task { await playerCoordinator.open(item: item) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // An ALBUM fills the WHOLE cover face
                // (aspectFill, top-aligned crop. Exactly like the other
                // Featured cards; the mosaic path rendered its big-bottom/
                // tint-top layout here, which read as an inverted color band).
                // Playlists keep the 2×2 mosaic. That IS their cover.
                Group {
                    if isAlbum {
                        // A card IN A ROW picks up the warm preview cache.
                        // Without the flag it shows the placeholder first on
                        // every re-entry, even when the image already lies in
                        // the cache.
                        CachedAsyncImage(url: coverURLs.first, useThumbnail: true) { image, pixels in
                            // The card face is large and only a few are on
                            // screen at once, so the blurred backdrop is
                            // affordable here; a wide picture stays whole
                            // instead of shrinking to a stamp over a crop.
                            CoverFitting(image: image, pixelSize: pixels, backdrop: .blurredSelf)
                        } placeholder: {
                            Rectangle().fill(tint)
                                .overlay(Image(systemName: "music.note")
                                    .font(.largeTitle).foregroundStyle(.white.opacity(0.5)))
                        }
                        .frame(width: CardMetrics.featuredCardWidth,
                               height: CardMetrics.featuredCardWidth, alignment: .top)
                        .clipped()
                    } else {
                        PlaylistArtwork(playlistID: mosaicKey, coverURLs: coverURLs, cornerRadius: 0)
                    }
                }
                    // Scrim only at the SEAM into the text block (edge
                    // continuity like every Featured card). Nothing tints
                    // the cover face itself.
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, tint],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: CardMetrics.featuredCardWidth * 0.3)
                    }
                    // The server's name with two music servers. Top
                    // left: the bottom edge fades into the text block.
                    .overlay(alignment: .topLeading) {
                        if let source = router.sourceLabel(item.id) {
                            CoverCapsule(text: source)
                        }
                    }
                VStack(alignment: .leading, spacing: 5) {
                    Text(captionText.isEmpty ? " " : captionText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: titleMinHeight, alignment: .topLeading)
                    Text(item.author ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: subMinHeight, alignment: .topLeading)
                }
                .padding(14)
                .padding(.bottom, pillReserve)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("music-continue-card")
        .frame(width: CardMetrics.featuredCardWidth)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.easeInOut(duration: 0.45), value: colorLoader.hasAccent)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .overlay(alignment: .bottomLeading) {
            CardDetailPill(value: MusicRoute.album(item)).padding(12)
        }
        // The SAME shuffle corner button as the playlist cards.
        // Second action only, the card TAP stays RESUME (the row's purpose);
        // music cards only, books/episodes are never shuffled.
        .overlay(alignment: .bottomTrailing) {
            CardCornerButton(systemImage: "shuffle",
                             accessibilityLabel: Text("Shuffle"),
                             accessibilityId: "music-continue-shuffle") {
                Task {
                    let items = await AppSession.shared.musicProvider(for: item.id).songItems(forItemId: item.id)
                    await playerCoordinator.shufflePlay(items: items,
                                                        contextSource: item.title)
                }
            }
            .padding(12)
        }
        // This card lives only in Continue contexts, so
        // it carries the same "take it off this row" entry as the book and
        // episode cards. The saved position is untouched.
        .contextMenu {
            Button {
                ContinueHiddenStore.hide(id: item.id, lastUpdate: progress?.lastUpdate ?? 0)
            } label: {
                Label("Don't show under Continue", systemImage: "eye.slash")
            }
        }
        .task(id: coverURLs.first) { await colorLoader.load(from: coverURLs.first) }
        .task(id: item.id) {
            let music = AppSession.shared.musicProvider(for: item.id)
            // An ALBUM has one cover. Skip the playlist mosaic lookup.
            if music.kind(of: item.id) == .album {
                coverURLs = [router.coverURL(item.id)].compactMap { $0 }
            } else {
                let ids = await music.playlistMosaicCoverIDs(forItemId: item.id)
                coverURLs = ids.compactMap { music.coverURL(coverArtId: $0) }
            }
        }
    }
}
