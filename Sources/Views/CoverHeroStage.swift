// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// 8d54582: THE hero cover stage — the book-detail page's full-bleed cover
/// anatomy (image fills the stage frame, clipped), extracted so the drive
/// mode reuses the SAME part instead of rebuilding it (Regel 2). The drive
/// mode additionally fades the stage's bottom edge into its background
/// (`fadeTo`); the book page keeps its own gradient backdrop and passes nil.
struct CoverHeroStage<CoverOverride: View>: View {
    let url: URL?
    var placeholderSymbol: String = "book.closed"
    /// Fade the BOTTOM edge into this color (nil = no fade — the host owns
    /// the backdrop, like the book detail).
    var fadeTo: Color? = nil
    /// 6b3a35d: a caller-supplied cover view replacing the URL image (drive
    /// mode passes `RadioArtwork` so the favicon gate + gradient/initials
    /// placeholder apply — the SAME chain as player/detail, no side path).
    /// Concrete generic, no AnyView (cell-cost rule).
    var coverOverride: CoverOverride?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let coverOverride {
                    coverOverride
                } else {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .overlay(Image(systemName: placeholderSymbol)
                                .font(.largeTitle).foregroundStyle(.secondary))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(alignment: .bottom) {
                if let fadeTo {
                    LinearGradient(colors: [.clear, fadeTo],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * 0.45)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

extension CoverHeroStage where CoverOverride == EmptyView {
    /// Existing call sites keep their shape (no override).
    init(url: URL?, placeholderSymbol: String = "book.closed", fadeTo: Color? = nil) {
        self.init(url: url, placeholderSymbol: placeholderSymbol,
                  fadeTo: fadeTo, coverOverride: nil)
    }
}
