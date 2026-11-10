// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How far planned tracks may join a playing queue, pure.
nonisolated enum QueueAppend {
    /// The first track that may not be appended: none while a load failure
    /// stopped playback (the next play builds anew), the held track while a
    /// later load failure is held (nothing may stand behind it), else none
    /// past the last.
    static func end(trackCount: Int, heldAt: Int?, failureNoted: Bool) -> Int {
        if failureNoted { return 0 }
        if let heldAt { return min(max(heldAt, 0), trackCount) }
        return trackCount
    }
}
