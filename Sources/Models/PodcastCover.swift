// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which picture an episode shows: its own, else its show's. An EMPTY
/// address is no picture. PodcastIndex answers `""` for an episode without
/// one, and an empty string beat the show's artwork in `??`, so the row
/// fell to the placeholder microphone instead of the show image.
nonisolated enum PodcastCover {
    /// An address that is there, or nil: trimmed, empty is nil.
    static func present(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func source(episodeImage: String?, showArtwork: String?) -> String? {
        present(episodeImage) ?? present(showArtwork)
    }
}
