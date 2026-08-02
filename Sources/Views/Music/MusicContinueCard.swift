// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Package 3: a playlist on the Home "Continue" row. Reuses the F5 2×2 mosaic
/// (`PlaylistArtwork`) as the cover — no new artwork path — over the title and a
/// progress bar; tapping resumes the playlist at its bookmarked position (the
/// provider hands `open` a `userMediaProgress` / the local backup covers same
/// device). Sized like the other featured continue cards.
struct MusicContinueCard: View {
    let item: LibraryItem
    let progress: BookProgress?
    @ObservedObject var playerCoordinator: PlayerCoordinator

    @State private var coverURLs: [URL] = []
    /// 7ade0cf: the text-block color comes from the cover EDGE the block
    /// touches — the SAME cached CoverColorLoader extraction the playlist
    /// cards use (one mechanism, deterministic fallback without a cover).
    /// bd66c5b: EXACT Featured-card anatomy — the mixed Continue row holds
    /// ONE card format (book · episode · album/playlist), so this card uses
    /// the same width, cover face, tint block, line reserves and pill as
    /// Book-/PodcastFeaturedCard; the mosaic/album cover simply fills the
    /// same frame. Color from the (bottom) cover like the playlist cards.
    @StateObject private var colorLoader = CoverColorLoader()
    @ScaledMetric(relativeTo: .subheadline) private var pillReserve: CGFloat = 40
    @ScaledMetric(relativeTo: .headline) private var titleMinHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var subMinHeight: CGFloat = 20

    private var mosaicKey: String { item.id }
    private var isAlbum: Bool { AppSession.shared.musicProvider.kind(of: item.id) == .album }

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
                // c58585e/7ade0cf: an ALBUM fills the WHOLE cover face
                // (aspectFill, top-aligned crop — exactly like the other
                // Featured cards; the mosaic path rendered its big-bottom/
                // tint-top layout here, which read as an inverted color band).
                // Playlists keep the F5 mosaic — that IS their cover.
                Group {
                    if isAlbum {
                        CachedAsyncImage(url: coverURLs.first) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
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
                    // continuity like every Featured card) — nothing tints
                    // the cover face itself.
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, tint],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: CardMetrics.featuredCardWidth * 0.3)
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
        .task(id: coverURLs.first) { await colorLoader.load(from: coverURLs.first) }
        .task(id: item.id) {
            let music = AppSession.shared.musicProvider
            // M1: an ALBUM has one cover — skip the playlist mosaic lookup.
            if music.kind(of: item.id) == .album {
                coverURLs = [AppSession.shared.coverURL(forItemId: item.id)].compactMap { $0 }
            } else {
                let ids = await music.playlistMosaicCoverIDs(forItemId: item.id)
                coverURLs = ids.compactMap { music.coverURL(coverArtId: $0) }
            }
        }
    }
}
