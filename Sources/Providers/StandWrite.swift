// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The one question every writer of a stand asks right before it writes:
/// is a duration of this work estimated (a Gutenberg work started before
/// all its durations were read)? Then a stand counted over its tracks would
/// carry the estimate to every device. The player's own writers skip and
/// say so; a mark, a person's act, waits for the real durations instead
/// (`AudioProvider.resolveDurations`).
@MainActor
enum StandWrite {
    static func allowed(itemId: String, provider: any AudioProvider) -> Bool {
        !provider.estimatesDurations(itemId: itemId, beforeTrack: .max)
    }
}
