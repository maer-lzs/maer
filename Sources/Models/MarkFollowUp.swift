// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What happens to a deliberate position write (a pause, a seek) that asked
/// while a finished mark held the guard of the writes: it runs once after the
/// mark, unless the mark wrote the title finished. That write is then the
/// newer stand, and the paused position would turn the title back to
/// unfinished.
nonisolated enum MarkFollowUp {
    static func origin<Origin>(asked: Origin?, markedFinished: Bool) -> Origin? {
        markedFinished ? nil : asked
    }
}
