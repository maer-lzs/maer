// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// THE explicit mark of podcasts (`itunes:explicit`): an episode carries it
/// by its own tag, and without one by its show's; a show by its own. The
/// mark is the letter E, on episode rows, the episode page and the show page
/// (`ExplicitMark`).
nonisolated enum PodcastExplicit {
    static let letter = "E"

    static func marks(episode: Bool?, show: Bool?) -> Bool {
        episode ?? show ?? false
    }

    static func marks(show: Bool?) -> Bool {
        show ?? false
    }
}
