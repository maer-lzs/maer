// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How the side-by-side book page carries its cover, by the height the page
/// has, never by the kind of device: a folded iPhone Duo on its side is as
/// short as a phone, an unfolded one as tall as an iPad, and an iPad window
/// can be short. A short page fills its full height with the sharp cover; a
/// taller one lets a blurred panel carry the height with the sharp cover
/// floating on top, since a full-height cover there would need a picture
/// larger than most servers send.
nonisolated enum BookDetailCover {
    /// Every phone on its side stays under this (440 pt at most), the folded
    /// Duo too (466 pt); an iPad on its side is far over it.
    static let sharpFillLimit: CGFloat = 480

    static func sharpFills(height: CGFloat) -> Bool {
        height <= sharpFillLimit
    }
}
