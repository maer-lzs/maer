// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How long a person waits after too many failed sign-ins, as it is said.
nonisolated enum MaerSyncWait {
    /// `Retry-After` seconds as whole minutes, rounded up and at least one:
    /// "try again in 0 min." would invite a try the service still refuses.
    static func minutes(_ seconds: Int) -> Int {
        max(1, (max(0, seconds) + 59) / 60)
    }
}
