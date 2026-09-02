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
/// Switch for the visible cover self-report. A launch argument rather
/// than a stored key: nothing persists, no sync class to declare, and
/// a UI test or an Xcode scheme can set it without touching the device.
enum CoverMarker {
    nonisolated static var isOn: Bool {
        ProcessInfo.processInfo.arguments.contains("-cover-marker")
    }
}

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
        // The marker hangs on a ZERO-size anchor, not on the picture: a
        // filled wide image is WIDER than its frame, so a badge pinned to
        // the image's own corner would land outside and be clipped away,
        // for exactly the wide pictures the badge exists to report.
        Color.clear
            .overlay(measured)
            .overlay(alignment: .topLeading) { marker }
    }

    @Environment(\.coverLoadAttempt) private var loadAttempt
    @Environment(\.coverLoadPot) private var loadPot

    /// The chain's visible self-report, only when `CoverMarker.isOn`:
    /// measured pixels, the fill/fit decision, how often this address
    /// was asked for and which pot answered. A device log cannot be read
    /// live and a debug log line is not guaranteed to reach an archive;
    /// a badge on the tile answers a scroll question in one screenshot.
    @ViewBuilder
    private var marker: some View {
        #if DEBUG
        if CoverMarker.isOn {
            Text(verbatim: "\(Int(pixelSize.width))x\(Int(pixelSize.height)) "
                 + (CoverAspect.needsFitting(width: pixelSize.width,
                                             height: pixelSize.height) ? "FIT" : "FILL")
                 + " #\(loadAttempt) \(loadPot)")
                .font(.system(size: 9, weight: .bold))
                .padding(2)
                .background(.red)
                .foregroundStyle(.white)
        }
        #endif
    }

    @ViewBuilder
    private var measured: some View {
        if CoverAspect.needsFitting(width: pixelSize.width, height: pixelSize.height) {
            // NOT a ZStack. A filled image REPORTS its full filled width
            // as its size, so a ZStack around it grows to that width, the
            // fitted picture then fits into the grown stack (full width
            // again) and the caller's clip crops it: the exact look of a
            // fill, measured on the device as "FIT" and cropped anyway.
            // `Color.clear` takes precisely the proposed size and overlays
            // never change it, so the fitted picture fits the TILE.
            Color.clear
                .overlay {
                    switch backdrop {
                    case .blurredSelf:
                        image.resizable().aspectRatio(contentMode: .fill)
                            .blur(radius: 18)
                            .overlay(Color.black.opacity(0.35))
                    case .neutral:
                        Rectangle().fill(.quaternary)
                    }
                }
                .overlay { image.resizable().aspectRatio(contentMode: .fit) }
                .clipped()
        } else {
            // Unchanged for everything that already looked right. This
            // branch is the one almost every cover takes.
            image.resizable().aspectRatio(contentMode: .fill)
        }
    }
}
