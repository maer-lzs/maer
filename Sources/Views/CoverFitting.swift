// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// How a cover meets its square tile, as ONE place.
///
/// Every cover surface used to write `image.resizable().aspectRatio(
/// contentMode: .fill)` itself, twenty-three times over. Filling suits a
/// cover and ruins a title card: a wide picture loses about a third of
/// its width, and on a card carrying words that is the difference
/// between a title and a fragment of one.
///
/// So a picture far from square is fitted WHOLE, and the tile's
/// remaining area carries a backdrop. The grid stays square either way,
/// because a grid of mixed shapes falls apart to look at.
///
/// The decision itself lives in `CoverAspect`, pure and tested. This
/// view only renders it.
struct CoverFitting: View {
    let image: Image
    /// Pixel size of the picture being shown, from `CachedAsyncImage`.
    /// It is the only view that knows it.
    let pixelSize: CGSize
    var backdrop: Backdrop = .blurredSelf

    /// What fills the tile beside a fitted picture.
    enum Backdrop {
        /// A blurred, darkened enlargement of the SAME picture. No
        /// second request and no second resolution: the bytes are
        /// already decoded and on screen.
        case blurredSelf
        /// A neutral fill, for surfaces where a blur per cell would be
        /// paid on every scrolled frame.
        case neutral
    }

    var body: some View {
        if CoverAspect.needsFitting(width: pixelSize.width, height: pixelSize.height) {
            ZStack {
                switch backdrop {
                case .blurredSelf:
                    image.resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 18)
                        .overlay(Color.black.opacity(0.35))
                case .neutral:
                    Rectangle().fill(.quaternary)
                }
                image.resizable().aspectRatio(contentMode: .fit)
            }
        } else {
            // Unchanged for everything that already looked right. This
            // branch is the one almost every cover takes.
            image.resizable().aspectRatio(contentMode: .fill)
        }
    }
}
